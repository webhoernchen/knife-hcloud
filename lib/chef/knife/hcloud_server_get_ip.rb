require 'knife_hcloud/base'
require 'knife_hcloud/config'

module KnifeHcloud
  class HcloudServerGetIp < Chef::Knife
    include KnifeHcloud::Base
    include KnifeHcloud::Config
    
    deps do
      require 'chef/json_compat'
    end
    
    banner "knife hcloud server get ip OPTIONS"

    option :chef_node_name,
      :short => '-N NAME',
      :long => '--node-name NAME',
      :description => 'The Chef node name for your new server node',
      :proc => Proc.new { |o| Chef::Config[:knife][:chef_node_name] = o }

    option :ip_v4_only,
      :short => '-4',
      :long => '--ipv4',
      :description => 'IPv4 only',
      :proc => Proc.new { |o| Chef::Config[:knife][:ip_v4_only] = true }

    option :ip_v6_only,
      :short => '-6',
      :long => '--ipv6',
      :description => 'IPv6 only',
      :proc => Proc.new { |o| Chef::Config[:knife][:ip_v6_only] = true }

    def run
      server = hcloud_client.servers.detect do |server|
        server.name == server_name
      end

      if server
        knife = Chef::Config[:knife]
        public_net = server.public_net

        if knife[:ip_v4_only]
          print public_net['ipv4']['ip']
        elsif knife[:ip_v6_only]
          result = public_net['ipv6']['dns_ptr'].collect do |ptr|
            ptr['ip']
          end.join("\n")
          print result
        else
          print "IPv4: #{public_net['ipv4']['ip']}\n"
          
          public_net['ipv6']['dns_ptr'].each do |ptr|
            print "IPv6: #{ptr['ip']}\n"
          end
        end
      else
        error "Server '#{server_name}' not found"
      end
    end
  end
end
