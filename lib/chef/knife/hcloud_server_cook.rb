require 'knife_hcloud/base'
require 'knife_hcloud/config'

module KnifeHcloud
  class HcloudServerCook < Chef::Knife
    include KnifeHcloud::Base
    include KnifeHcloud::Config
    
    deps do
      require 'net/ssh'
      require 'ipaddress'
      require 'net/ssh/multi'
      
#      require 'chef/mixin/command'
      require 'chef/knife'
      require 'chef/knife/solo_bootstrap'
      require 'chef/knife/solo_cook'
      require 'chef/json_compat'
      
      require 'securerandom'
      require 'timeout'
      require 'socket'
    end

    banner 'knife hcloud server cook OPTIONS'

    option :run_list,
      :short => '-r RUN_LIST',
      :long => '--run-list RUN_LIST',
      :description => 'Comma separated list of roles/recipes to apply',
      :proc => lambda { |o| Chef::Config[:deprecated_error] = "\n-r or --run-list is deprecated and will be removed soon!\nPlease use -o or --override-runlist"; Chef::Config[:knife][:override_runlist] = o },
      :default => []
    
    option :override_runlist,
      :short       => '-o RunlistItem,RunlistItem...,',
      :long        => '--override-runlist',
      :description => 'Replace current run list with specified items (Comma separated list of roles/recipes)',
      :proc => lambda { |o| Chef::Config[:knife][:override_runlist] = o },
      :default => []

    option :hcloud_image,
      :short => '-image NAME',
      :long => '--hcloud-image NAME',
      :description => 'Profitbricks image name',
      :proc => lambda { |o| Chef::Config[:knife][:profitbricks_image] = o }

    option :chef_node_name,
      :short => '-N NAME',
      :long => '--node-name NAME',
      :description => 'The Chef node name for your new server node',
      :proc => Proc.new { |o| Chef::Config[:knife][:chef_node_name] = o }

    option :forward_agent,
      :short => '-A',
      :long        => '--forward-agent',
      :description => 'Forward SSH authentication. Adds -E to sudo, override with --sudo-command.',
      :boolean     => true,
      :default     => false,
      :proc => Proc.new { |o| Chef::Config[:knife][:forward_agent] = o }

    def run
      error Chef::Config[:deprecated_error] if Chef::Config[:deprecated_error]

#      p boot_image_name
#      p boot_image
#
#      p server_name
#
#      p hcloud_location_name
#      p hcloud_location
#
#      p server_type_name
#      p server_type

      server
      handle_volumes
      update_ptr
      error 'Server is not available by ssh' unless server_available_by_ssh?
      update_known_hosts if @server_is_new
      prepare_server_for_chef if @server_is_new
      bootstrap_or_cook
      reboot_server if @server_is_new
      delete_unused_volumes
    end

    private
    def server
      @server ||= detect_server || create_server
    end

    def detect_server
      server = hcloud_client.servers.find_by :name => server_name

      if server && server.status == 'off'
#        response = server.poweron
#        action = Hcloud::Action.new client, response.parsed_json[:action]
        action = server.poweron
        log_action action: action, server: server
        hcloud_client.servers.find server.id
      else
        server
      end
    end

    def create_server
      action, server, root_password = hcloud_client.servers.create name: server_name,
        server_type: server_type.id,
        start_after_create: true,
        image: boot_image,
        ssh_keys: [current_ssh_key.id],
        datacenter: hcloud_location.id

      log_action action: action, server: server
      @server_is_new = true
      hcloud_client.servers.find server.id
    end

    def current_ssh_key
      @current_ssh_key ||= _current_ssh_key
    end

    def _current_ssh_key
      public_ssh_key_file = Dir.glob(File.join(ENV['HOME'], '.ssh', '*.pub')).first
      log "Use ssh public key: #{public_ssh_key_file}"
      log ''
      
      public_ssh_key = File.read(public_ssh_key_file).strip
      ssh_key = hcloud_client.ssh_keys.detect do |key| # can not be used with find_by
        key.public_key == public_ssh_key
      end

      ssh_key ||= hcloud_client.ssh_keys.create name: ENV['USER'], public_key: public_ssh_key
    end

    def handle_volumes
      create_or_update_volumes
      File.open(node_config_file, 'w+') {|f| f.write JSON.pretty_generate node_config } unless server_volumes.empty?
    end

    def server_volumes
      server_config['volumes'] ||= {}
    end

    def create_or_update_volumes
      server_volumes.each do |name, options|
        volume_name = [server_name, name].join('-')
        size = options['size']

        # server can not be filtered by where
        volume = hcloud_client.volumes.where(:name => volume_name).detect do |volume|
          volume.server == server.id
        end

        unless volume
          action, volume = hcloud_client.volumes.create name: volume_name,
            server: server.id, size: size, automount: false, format: options['format']
          
          log_action action: action, volume: volume
          volume = hcloud_client.volumes.find volume.id
        end

        if volume.size < size
          action = volume.resize size: size
          log_action action: action, volume: volume
          volume = hcloud_client.volumes.find volume.id
        elsif volume.size > size
          log_error "Volume is already #{volume.size}GB. Config is #{size}GB"
        end unless volume.size == size

        options['linux_device'] = volume.linux_device
      end
    end

    def delete_unused_volumes
      names = server_volumes.collect do |name, options|
        [server_name, name].join('-')
      end

      hcloud_client.volumes.select do |volume|
        volume.server == server.id
      end.select do |volume|
        !names.include? volume.name
      end.each do |volume|
        action = volume.detach
        log_action action: action
        volume = hcloud_client.volumes.find volume.id
        
        action = volume.destroy
        log_action action: action
      end
    end

    def update_ptr
      update_ptr_ipv4
      update_ptr_ipv6
    end

    def update_ptr_ipv4
      ip_resource = server.public_net['ipv4']
      if ptr_record && ip_resource['dns_ptr'] != ptr_record
        action = server.change_dns_ptr ip: ip_resource['ip'], dns_ptr: ptr_record

        log_action action: action, server: server
        @server = hcloud_client.servers.find server.id
      end
    end

    def update_ptr_ipv6
      ip_resource = server.public_net['ipv6']
      dns_ptr = ip_resource['dns_ptr'].first

      if ptr_record && !dns_ptr || dns_ptr['dns_ptr'] != ptr_record
        ip = IPAddr.new ip_resource['ip']
        sec = ip.to_range.first
        sec = sec.class.new sec.to_s + '1'
        action = server.change_dns_ptr ip: sec.to_s, dns_ptr: ptr_record
        
        log_action action: action, server: server
        @server = hcloud_client.servers.find server.id
      end
    end

    def ptr_record
      @ptr_record ||= detect_ptr_record
    end

    def detect_ptr_record
      a_records.collect do |domain, hosts|
        hosts.collect do |host|
          [host, domain].delete_if(&:blank?).join('.')
        end
      end.flatten.first if a_records
    end

    def a_records
      @a_records ||= if node_config.key? 'a_records'
        node_config['a_records']
      else
        node_config['ssl_domains'] || {}
      end
    end

    def update_known_hosts
      known_hosts_file = File.join(ENV['HOME'], '.ssh', 'known_hosts').to_s

      entries = server_ips.dup
      entries << ptr_record
      entries.each do |ip|
        system("ssh-keygen -R #{ip}")
        system("ssh-keyscan #{ip} >> #{known_hosts_file}")
      end
    end

    def server_ips
      @server_ips ||= _server_ips
    end

    def _server_ips
      ips = []
      ips << server.public_net['ipv4']['ip']
      ips += server.public_net['ipv6']['dns_ptr'].collect {|ptr| ptr['ip'] }
    end

    def prepare_server_for_chef
      new_user = Chef::Config[:knife][:ssh_user]
      result = {}
      
      Net::SSH.start(server_ips.first, 'root', :compression => true) do |ssh|
        ssh.exec! "useradd #{new_user} -G sudo -m -s /bin/bash", :status => result
        ssh.exec! "mkdir -p /home/#{new_user}/.ssh && cat .ssh/authorized_keys > /home/#{new_user}/.ssh/authorized_keys && chmod -R go-rwx /home/#{new_user}/.ssh && chown -R lchef /home/#{new_user}/.ssh", :status => result

        data = <<-END.lstrip
# /etc/sudoers.d/chef
#
# This file MUST be edited with the 'visudo' command as root.
# See the man page for details on how to write a sudoers file.
# Defaults
#
# Generated by Chef

User_Alias CHEF_USERS = #{new_user}

# Cmnd alias specification

# User privilege specification
Runas_Alias CHEF_RUNAS = root

CHEF_USERS ALL = (CHEF_RUNAS) NOPASSWD: ALL
END
        ssh.open_channel do |channel|
          channel.exec('dd of=/etc/sudoers.d/chef') do |ch, success|
            channel.send_data data
            channel.eof!
          end
        end

        ssh.exec! 'chmod 0440 /etc/sudoers.d/chef', :status => result
      end
    end

    def custom_timeout(*args, &block)
      if defined?(Timeout) && Timeout.respond_to?(:timeout)
        Timeout.timeout(*args, &block)
      else
        timeout(*args, &block)
      end
    end
        
    def server_available_by_ssh?
      max_retries = 10
      max_retries.times.detect do |n|
        result = ssh_test :time => n.next, :retries => max_retries
        sleep 5 unless result
        result
      end
    end

    def ssh_test(options={})
      begin
        custom_timeout 5 do
          s = TCPSocket.new server_ips.first, 22
          s.close
          true
        end
      rescue Timeout::Error, Errno::ECONNREFUSED, Net::SSH::Disconnect, Net::SSH::ConnectionTimeout, IOError => e
        info = options.empty? ? nil : "#{options[:time]} / #{options[:retries]}"
        log '  * ' + [e.class, server_ips.first, Time.now.to_s, info].compact.collect(&:to_s).join(' - ')
        false
      end
    end
    
    def bootstrap_or_cook
      command = "dpkg -l | grep ' chef' | awk '{print $3}' | egrep -o '([0-9]+\\.)+[0-9]+'"
      versions = `ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no #{Chef::Config[:knife][:ssh_user]}@#{server_ips.first} "#{command}"`.strip.split("\n").collect(&:strip)

      log "Chef version on server '#{server_name}': #{versions.join(', ')}"
      log "Local chef version: #{Chef::VERSION}"
      
      chef_klass = if !versions.empty? && versions.any? {|v| v >= Chef::VERSION }
        cook
      else
        bootstrap
      end
      
      chef_klass.load_deps
      chef = chef_klass.new
      chef.name_args = [server_ips.first]
      chef.config[:override_runlist] = Chef::Config[:knife][:override_runlist] if Chef::Config[:knife][:override_runlist]
      chef.config[:ssh_user] = Chef::Config[:knife][:ssh_user]
      chef.config[:host_key_verify] = false
      chef.config[:chef_node_name] = Chef::Config[:knife][:chef_node_name]
      chef.config[:forward_agent] = Chef::Config[:knife][:forward_agent]
      #chef.config[:use_sudo] = true unless bootstrap.config[:ssh_user] == 'root'
#      chef.config[:sudo_command] = "echo #{Shellwords.escape(user_password)} | sudo -ES" if @server_is_new
      chef.config[:ssh_control_master] = 'no'
      chef.config[:ssh_keepalive_interval] = 30
      chef.config[:ssh_keepalive] = true
      chef.run
    end

    def bootstrap
      log "Boostrap server..."
      Chef::Knife::SoloBootstrap
    end

    def cook
      log "Cook server..."
      Chef::Knife::SoloCook
    end
      
    def ssh(command)
      ssh = Chef::Knife::Ssh.new
      ssh.ui = ui
      ssh.name_args = [ server_ips.first, command ]
      ssh.config[:ssh_port] = 22
      #ssh.config[:ssh_gateway] = Chef::Config[:knife][:ssh_gateway] || config[:ssh_gateway]
      #ssh.config[:identity_file] = locate_config_value(:identity_file)
      ssh.config[:manual] = true
      ssh.config[:host_key_verify] = false
      ssh.config[:on_error] = :raise
      ssh
    end

    def ssh_root(command)
      s = ssh(command)
      s.config[:ssh_user] = 'root'
#      s.config[:ssh_password] = root_password
      s
    end

    def ssh_user(command)
      s = ssh(command)
      s.config[:ssh_user] = Chef::Config[:knife][:ssh_user]
      s
    end

    def reboot_server
      user_and_server = "#{Chef::Config[:knife][:ssh_user]}@#{server_ips.first}"

      installed_kernel = `ssh #{user_and_server} "ls /boot/initrd.img-* | sort -V -r | head -n 1 | sed -e 's/\\/boot\\/initrd\\.img-//g'"`.strip
      loaded_kernel = `ssh #{user_and_server} "uname -r"`.strip

      if installed_kernel != loaded_kernel
        log 'Reboot server ...'
        
        begin
          ssh('sudo reboot').run
        rescue IOError => e
          raise e unless e.message == 'closed stream'
        end

        sleep 30

        if server_available_by_ssh?
          log 'Server is available!'
          log ''
        else
          error 'Server reboot failed!'
        end
      end
    end
  end
end
