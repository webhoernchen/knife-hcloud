require 'knife_hcloud/base'
require 'knife_hcloud/config'

module KnifeHcloud
  class HcloudServerCook < Chef::Knife
    include KnifeHcloud::Base
    include KnifeHcloud::Config
    
    deps do
      require 'net/ssh'
      require 'ipaddress'
#      require 'net/ssh/multi'
      
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
#      p detect_hcloud_location
#
#      p server_type_name
#      p detect_server_type

      server
      update_ptr
      error 'Server is not available by ssh' unless server_available_by_ssh?
      update_known_hosts if @server_is_new
      prepare_server_for_chef if @server_is_new
    end

    private
    def server
      @server ||= detect_server || create_server
    end

    def detect_server
      server = hcloud_client.servers.detect do |server|
        server.name == server_name
      end

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
        server_type: detect_server_type,
        start_after_create: true,
        image: boot_image,
        ssh_keys: [current_ssh_key.id],
        datacenter: detect_hcloud_location

      log_action action: action, server: server
      @server_is_new = true
      hcloud_client.servers.find server.id
    end

    def log_action(action:, server:nil, wait: 5, &block)
      while action.status == 'running' || action.status != 'error' && (server.nil? || server.status != 'running')
        log "Waiting for Action #{action.id} to complete (#{action.progress}%) ..."
        log "Action (#{action.command}) Status: #{action.status}"
        log "Server Status: #{server.status}" if server
#        log "Server IP Config: #{server.public_net['ipv4']}" if server
        yield action: action, server: server if block_given?
        log ''
        sleep wait
        action = hcloud_client.actions.find action.id
        server = hcloud_client.servers.find server.id if server
      end
      
      log "Action (#{action.command}) Status: #{action.status}"
      log "Server Status: #{server.status}" if server
      log ''
    
      unless action.status == 'success'
        p action
        error "Action #{action.id} is failed"
      end
    end

    def current_ssh_key
      @current_ssh_key ||= _current_ssh_key
    end

    def _current_ssh_key
      public_ssh_key_file = Dir.glob(File.join(ENV['HOME'], '.ssh', '*.pub')).first
      log "Use ssh public key: #{public_ssh_key_file}"
      log ''
      
      public_ssh_key = File.read(public_ssh_key_file).strip
      ssh_key = hcloud_client.ssh_keys.detect do |key|
        key.public_key == public_ssh_key
      end

      ssh_key ||= hcloud_client.ssh_keys.create name: ENV['USER'], public_key: public_ssh_key
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
      a_records = node_config['a_records']
      a_records.collect do |domain, hosts|
        hosts.collect do |host|
          [host, domain].join('.')
        end
      end.flatten.first if a_records
    end

    def update_known_hosts
      known_hosts_file = File.join(ENV['HOME'], '.ssh', 'known_hosts').to_s

      server_ips.each do |ip|
        system("ssh-keygen -R #{ip}")
        system("ssh-keyscan #{ip} >> #{known_hosts_file}")
      end
    end

    def server_ips
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
  end
end
