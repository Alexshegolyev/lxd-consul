#!/usr/bin/env bash

# DISCLAIMER: Only use for development or testing purposes. Only tested on Ubuntu 16.04 LTS.
# AUTHOR: Mario Harvey https://marioharvey.com
command_exists () {
    type "$1" &> /dev/null ;
}

user="$(id -un 2>/dev/null || true)"

  if [ "$user" != 'root' ]; then
    if command_exists sudo; then
      sh_c='sudo -E sh -c'
    elif command_exists su; then
      sh_c='su -c'
    else
      cat >&2 <<-'EOF'
      Error: this script requires root or sudo as it will install wget and unzip if it doesn't exist.
      We are unable to find either "sudo" or "su" available to make this happen.
EOF
      exit 1
    fi
  fi

get_consul_ip(){
	/usr/bin/lxc info "$1" | grep 'eth0:\sinet\s' | awk 'NR == 1 { print $3 }'
}


start(){
	echo 'starting consul containers...'
	/usr/bin/lxc start consul1 consul2 consul3
}

stop(){
	echo 'stopping consul containers...'
	/usr/bin/lxc stop consul1 consul2 consul3 > /dev/null 2>&1
}

destroy(){
	echo 'destroying lxd-consul cluster...'
	# stopping cluster
    stop
	# delete containers
	echo 'deleting consul containers...'
	/usr/bin/lxc delete -f consul1 consul2 consul3

	echo 'lxd-consul destroyed!'
}


create(){
  # set consul version
  version='0.6.4'

  # set os version
  os_version='3.4'
  
  # check if lxc client is installed. if not exit out and tell to install
  if command_exists lxc; then
  	echo 'lxc client appears to be there. Proceeding with cluster creation...'
  	sleep 1
  else
  	echo 'lxd does not appear to be installed properly. Follow instructions here: https://linuxcontainers.org/lxd/getting-started-cli'
  fi

  # istall packages required
  $sh_c "apt update && apt install unzip wget -y"
  
  # download consul and extract into directory
  /usr/bin/wget https://releases.hashicorp.com/consul/$version/consul_"$version"_linux_amd64.zip -O "consul_$version.zip"
  /usr/bin/unzip -o "consul_$version.zip"
  /bin/rm "consul_$version.zip"
  
  # get base lxd image
  echo "copying down base Alpine $os_version image..."
  /usr/bin/lxc image copy images:alpine/$os_version/amd64 local: --alias=alpine$os_version

  names=(consul1 consul2 consul3)
  
  for name in "${names[@]}";
    do
      # create containers
      /usr/bin/lxc launch alpine$os_version "$name" -c security.privileged=true
      # make consul dirs
      /usr/bin/lxc exec "$name" -- mkdir -p /consul/data
      /usr/bin/lxc exec "$name" -- mkdir -p /consul/server
      # move consul binary into containers
      /usr/bin/lxc file push consul "$name"/usr/bin/
  done
  
  x=0
  echo 'Getting IP for Consul Bootstrap instance...'
  #get the ip for consul bootstrap instance
  while [ -z "$bootstrap_ip" ]
    do
      if [ "$x" -gt 15 ]; then echo 'Cannot get an IP for the consul instance. Please check lxd bridge and try again. Cleaning...'; destroy; exit 2; fi
      bootstrap_ip=$(get_consul_ip consul1)
      ((x++))
      sleep 2
  done

  consul2_ip=$(get_consul_ip consul2)
  consul3_ip=$(get_consul_ip consul3)

  # create bootstrap config with ip address
  /bin/sed s/myaddress/"$bootstrap_ip"/g config/bootstrap.json > bootstrap_consul1.json
  # move in bootstrap config into container into bootstrap directory
  /usr/bin/lxc exec consul1 -- mkdir -p /consul/bootstrap
  /usr/bin/lxc file push bootstrap_consul1.json consul1/consul/bootstrap/
  # move in bootstrap init script and make executable
  /usr/bin/lxc file push config/consul-bootstrap consul1/etc/init.d/
  /usr/bin/lxc exec consul1 -- chmod 755 /etc/init.d/consul-bootstrap 
  # launch bootstrap
  /usr/bin/lxc exec consul1 -- rc-service consul-bootstrap start
  #create server config files
  /bin/sed s/ips/"$bootstrap_ip\", \"$consul3_ip"/g config/server.json > server_consul2.json
  /bin/sed s/ips/"$bootstrap_ip\", \"$consul2_ip"/g config/server.json > server_consul3.json
  /bin/sed s/ips/"$consul2_ip\", \"$consul3_ip"/g config/server.json > server_consul1.json
  
  # push server config files and init script to server nodes
  for name in "${names[@]}";
    do
    /usr/bin/lxc file push server_"$name".json $name/consul/server/
    /usr/bin/lxc file push config/consul-server $name/etc/init.d/
    /usr/bin/lxc exec $name -- chmod 755 /etc/init.d/consul-server
  done
  
  #start server nodes
  /usr/bin/lxc exec consul2 -- rc-service consul-server start
  /usr/bin/lxc exec consul3 -- rc-service consul-server start
  #verify cluster health
  
  #shutdown bootstrap on consul1

  #start server on consul1
  
  # cleanup
  /bin/rm bootstrap_consul1.json
  /bin/rm -f server_consul*
  /bin/rm consul

echo '              lxd-consul setup complete!           '
echo '***************************************************'
echo '                    consul ui links                ' 
echo "             * http://$bootstrap_ip:8500           "
echo "             * http://$consul2_ip:8500             "
echo "             * http://$consul3_ip:8500             "
echo '***************************************************'
}

case "$1" in
	create)
      create
      ;;
    destroy)
      destroy
      ;;
    start)
      start
      ;;
    stop)
      stop
      ;;
    *) 
      echo "Usage: $0 command {options:create,destroy,start,stop}"
      exit 1
esac