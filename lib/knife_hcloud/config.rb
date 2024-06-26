module KnifeHcloud
  module Config

    private
    def node_config_file
      @node_config_file ||= _node_config_file
    end

    def _node_config_file
      n = Chef::Config[:knife][:chef_node_name]
      "nodes/#{n}.json"
    end

    def _node_config
      JSON.parse File.read node_config_file
    rescue Errno::ENOENT
      error "Node #{Chef::Config[:knife][:chef_node_name].inspect} not exist"
    end

    def node_config
      @node_config ||= _node_config
    end

    def _hcloud_config
      config = node_config['hcloud']
      error "No hcloud config found! Please specify \"hcloud\" in your node!" unless config
      config
    end

    def hcloud_config
      @hcloud_config ||= _hcloud_config
    end

    def hcloud_token_account
      hcloud_config['token']
    end

    def hcloud_location_name
      hcloud_config['location']
    end


    IN_GERMANY = 'any_in_germany'
    IN_EU = 'any_in_eu'
    def hcloud_location
      if hcloud_location_name == IN_GERMANY
        all_available_hcloud_locations_sorted_by_usage.detect do |datacenter|
          datacenter.location.country == 'DE'
        end
      elsif hcloud_location_name == IN_EU
        all_available_hcloud_locations_sorted_by_usage.first
      else
        hcloud_locations[hcloud_location_name] || \
          error("No location for #{hcloud_location_name.inspect}; available: #{hcloud_locations.keys.sort.join(', ')}")
      end
    end

    def hcloud_locations
      @hcloud_locations ||= all_available_hcloud_locations.inject({}) do |sum, datacenter|
        key = datacenter.location.city.downcase
        error "Datacenter #{datacenter.name} already exists in #{sum.keys.join(', ')}" if sum[key]
        sum.merge key => datacenter
      end
    end

    def all_available_hcloud_locations_sorted_by_usage
      @all_available_hcloud_locations_sorted_by_usage ||= all_available_hcloud_locations.sort_by do |datacenter|
        all_servers_by_type.select {|s| s.datacenter.id == datacenter.id }.count
      end
    end

    def all_available_hcloud_locations
      @all_available_hcloud_locations ||= hcloud_client.datacenters.select do |datacenter|
        datacenter.location.network_zone == 'eu-central'
      end.select do |datacenter|
        datacenter.server_types[:supported].include?(server_type.id) &&
          datacenter.server_types[:available].include?(server_type.id)
      end
    end

    def server_config
      @server_config ||= hcloud_config['server']
    end

    def server_name
      server_config['name']
    end

    def boot_image_name
      @image_name ||= if image = server_config['image']
        if m = image.match(/^\/(.*)\/$/)
          Regexp.new m[1]
        else
          image
        end
      else
        Chef::Config[:knife][:hcloud_image]
      end
    end

    def boot_image
      @image ||= detect_boot_image
    end

    def detect_boot_image
      if boot_image_name.is_a? Regexp
        key = boot_images.keys.grep(boot_image_name).sort.last
        boot_images[key] if key
      else
        boot_images[boot_image_name]
      end || error("No boot image found for #{boot_image_name.inspect}; available: #{boot_images.keys.sort.join(', ')}")
    end

    def boot_images
      @boot_images ||= hcloud_client.images.select do |img|
        img.type == 'system' && img.status == 'available' && img.architecture == server_type.architecture #&& img.os_flavor == 'ubuntu'
      end.inject({}) do |sum, img|
        key = [img.os_flavor, img.os_version].join('_').gsub('.', '_')
        sum.merge key => img.id
      end
    end

    def server_type_name
      server_config['type']
    end

    def server_type
      server_types[server_type_name] || \
        error("No server type for #{server_type_name.inspect}; available: #{server_types.keys.sort.join(', ')}")
    end

    def server_types
      @server_types ||= hcloud_client.server_types.inject({}) do |sum, server_type|
        key = server_type.name
        error "Server type #{server_type.name} already exists in #{sum.keys.join(', ')}" if sum[key]
        sum.merge key => server_type
      end
    end

    # all servers which required type
    def all_servers_by_type
      @all_servers_by_type ||= hcloud_client.servers.select do |server|
        server.server_type.id == server_type.id
      end
    end
      
#    def root_password(reset=false)
#      @root_password = nil if reset
#      @root_password ||= SecureRandom.hex
#    end
#
#    def user_password(reset=false)
#      @user_password = nil if reset
#      @user_password ||= SecureRandom.hex
#    end
  end
end
