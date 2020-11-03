module KnifeHcloud
  module Base

    def self.included(base)
      base.class_eval do 
        deps do 
          require 'hcloud'
          require 'chef/knife'
#          require 'active_support/core_ext/string'
      
          Chef::Knife.load_deps
          
          Chef::Config[:solo] = true
          Chef::Config[:solo_legacy_mode] = true
        end

        option :hcloud_data_bag,
          :short => '-a NAME',
          :long => '--hcloud-data-bag NAME',
          :description => 'Data bag for hcloud account',
          :proc => lambda { |o| Chef::Config[:knife][:hcloud_data_bag] = o }

        def self.method_added(name)
          if name.to_s == 'run' && !@run_added
            @run_added = true
            alias run_without_establish_connection run
            alias run run_with_establish_connection
          end
        end
      end
    end

    def run_with_establish_connection
      establish_connection
      run_without_establish_connection
    end

    private
    def establish_connection
      token = detect_token
      log "Establish connection to Hcloud for #{token[0..4].inspect}"
      
      hcloud_client

      log 'Established ...'
      log "\n"
    end

    def hcloud_client
      @hcloud_client ||= Hcloud::Client.new token: detect_token
    end

    def load_data_bag(*args)
      secret_path = Chef::Config[:encrypted_data_bag_secret]
      secret_key = Chef::EncryptedDataBagItem.load_secret secret_path
      content = Chef::DataBagItem.load(*args).raw_data
      Chef::EncryptedDataBagItem.new(content, secret_key).to_hash
    end

    def detect_token
      @detected_token ||= if data_bag_name = Chef::Config[:knife][:hcloud_data_bag]
        data_bag = load_data_bag 'hcloud', data_bag_name

        data_bag['token']
      elsif hcloud_token_account
        data_bag = load_data_bag 'hcloud', hcloud_token_account

        data_bag['token']
      else
        ENV['HCLOUD_TOKEN']
      end
    end

    def log(m)
      ui.info m
    end

    def log_error(m)
      error m, :abort => false
    end

    def error(m, options={})
      ui.error m
      exit 1 if !options.has_key?(:abort) || options[:abort]
    end

    def log_action(action:, server:nil, wait: 5, &block)
      while action.status == 'running' || action.status != 'error' && server && server.status != 'running'
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
  end
end
