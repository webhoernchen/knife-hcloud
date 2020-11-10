require 'knife_hcloud/base'
require 'knife_hcloud/config'

module KnifeHcloud
  class HcloudServerCreateSnapshot < Chef::Knife
    include KnifeHcloud::Base
    include KnifeHcloud::Config
    
    deps do
      require 'chef/json_compat'
    end
    
    banner "knife hcloud server create snapshot OPTIONS"

    option :chef_node_name,
      :short => '-N NAME',
      :long => '--node-name NAME',
      :description => 'The Chef node name for your new server node',
      :proc => Proc.new { |o| Chef::Config[:knife][:chef_node_name] = o }

    def run
      server = hcloud_client.servers.detect do |server|
        server.name == server_name
      end

      if server
        timestamp = Time.now.strftime '%Y%m%d%H%M%S%L'
        description = [server_name, timestamp].join('-')
        image = server.create_image type: 'snapshot', description: description
        log_action action: action
      else
        error "Server '#{server_name}' not found"
      end
    end
  end
end
