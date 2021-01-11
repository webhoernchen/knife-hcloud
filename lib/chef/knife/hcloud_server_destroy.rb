require 'knife_hcloud/base'
require 'knife_hcloud/config'

module KnifeHcloud
  class HcloudServerDestroy < Chef::Knife
    include KnifeHcloud::Base
    include KnifeHcloud::Config
    
    deps do
      require 'chef/json_compat'
    end
    
    banner "knife hcloud server destroy OPTIONS"

    option :chef_node_name,
      :short => '-N NAME',
      :long => '--node-name NAME',
      :description => 'The Chef node name for your new server node',
      :proc => Proc.new { |o| Chef::Config[:knife][:chef_node_name] = o }

    def run
      server = hcloud_client.servers.find_by :name => server_name

      if server
        hcloud_client.volumes.select do |volume|
          volume.server == server.id
        end.each do |volume|
          action = volume.detach
          log_action action: action
          volume = hcloud_client.volumes.find volume.id
          
          action = volume.destroy
          log_action action: action if action.respond_to? :status
        end

        server = hcloud_client.servers.find server.id
        action = server.destroy
        log_action action: action
      else
        error "Server '#{server_name}' not found"
      end
    end
  end
end
