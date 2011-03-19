#
# Author:: Adam Jacob (<adam@opscode.com>)
# Copyright:: Copyright (c) 2009 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'fog'
require 'chef/knife'
require 'chef/knife/bootstrap'
require 'chef/json_compat'
require 'resolv'

class Chef
  class Knife
    class RackspaceServerCreate < Knife

      banner "knife rackspace server create [RUN LIST...] (options)"

      option :flavor,
        :short => "-f FLAVOR",
        :long => "--flavor FLAVOR",
        :description => "The flavor of server",
        :proc => Proc.new { |f| Chef::Config[:knife][:flavor] = f.to_i },
        :default => 1

      option :image,
        :short => "-i IMAGE",
        :long => "--image IMAGE",
        :description => "The image of the server",
        :proc => Proc.new { |i| Chef::Config[:knife][:image] = i.to_i }

      option :server_name,
        :short => "-S NAME",
        :long => "--server-name NAME",
        :description => "The server name"

      option :chef_node_name,
        :short => "-N NAME",
        :long => "--node-name NAME",
        :description => "The Chef node name for your new node"

      option :ssh_user,
        :short => "-x USERNAME",
        :long => "--ssh-user USERNAME",
        :description => "The ssh username",
        :default => "root"

      option :ssh_password,
        :short => "-P PASSWORD",
        :long => "--ssh-password PASSWORD",
        :description => "The ssh password"

      option :api_key,
        :short => "-K KEY",
        :long => "--rackspace-api-key KEY",
        :description => "Your rackspace API key",
        :proc => Proc.new { |key| Chef::Config[:knife][:rackspace_api_key] = key }

      option :api_username,
        :short => "-A USERNAME",
        :long => "--rackspace-api-username USERNAME",
        :description => "Your rackspace API username",
        :proc => Proc.new { |username| Chef::Config[:knife][:rackspace_api_username] = username }

      option :prerelease,
        :long => "--prerelease",
        :description => "Install the pre-release chef gems"

      option :distro,
        :short => "-d DISTRO",
        :long => "--distro DISTRO",
        :description => "Bootstrap a distro using a template",
        :default => "ubuntu10.04-gems",
        :proc => Proc.new { |d| Chef::Config[:knife][:distro] = d }

      option :use_sudo,
        :long => "--sudo",
        :description => "Execute the bootstrap via sudo",
        :boolean => false

      option :template_file,
        :long => "--template-file TEMPLATE",
        :description => "Full path to location of template to use",
        :default => false,
        :proc => Proc.new { |t| Chef::Config[:knife][:template_file] = t }

      def h
        @highline ||= HighLine.new
      end

      def tcp_test_ssh(hostname)
        tcp_socket = TCPSocket.new(hostname, 22)
        readable = IO.select([tcp_socket], nil, nil, 5)
        if readable
          Chef::Log.debug("sshd accepting connections on #{hostname}, banner is #{tcp_socket.gets}")
          yield
          true
        else
          false
        end
      rescue Errno::ETIMEDOUT
        false
      rescue Errno::ECONNREFUSED
        sleep 2
        false
      ensure
        tcp_socket && tcp_socket.close
      end

      def run
        require 'fog'
        require 'highline'
        require 'net/ssh/multi'
        require 'readline'

        $stdout.sync = true

        connection = Fog::Compute.new(
          :provider => 'Rackspace',
          :rackspace_api_key => Chef::Config[:knife][:rackspace_api_key],
          :rackspace_username => Chef::Config[:knife][:rackspace_api_username]
        )

        server = connection.servers.create(
          :name => config[:server_name],
          :image_id => Chef::Config[:knife][:image],
          :flavor_id => Chef::Config[:knife][:flavor]
        )

        puts "#{h.color("Instance ID", :cyan)}: #{server.id}"
        puts "#{h.color("Host ID", :cyan)}: #{server.host_id}"
        puts "#{h.color("Name", :cyan)}: #{server.name}"
        puts "#{h.color("Flavor", :cyan)}: #{server.flavor.name}"
        puts "#{h.color("Image", :cyan)}: #{server.image.name}"

        print "\n#{h.color("Waiting server", :magenta)}"

        # wait for it to be ready to do stuff
        server.wait_for { print "."; ready? }

        puts("\n")

        puts "#{h.color("Public DNS Name", :cyan)}: #{public_dns_name(server)}"
        puts "#{h.color("Public IP Address", :cyan)}: #{server.addresses["public"][0]}"
        puts "#{h.color("Private IP Address", :cyan)}: #{server.addresses["private"][0]}"
        puts "#{h.color("Password", :cyan)}: #{server.password}"

        print "\n#{h.color("Waiting for sshd", :magenta)}"

        print(".") until tcp_test_ssh(server.addresses["public"][0]) { sleep @initial_sleep_delay ||= 10; puts("done") }

        bootstrap_for_node(server).run

        puts "\n"
        puts "#{h.color("Instance ID", :cyan)}: #{server.id}"
        puts "#{h.color("Host ID", :cyan)}: #{server.host_id}"
        puts "#{h.color("Name", :cyan)}: #{server.name}"
        puts "#{h.color("Flavor", :cyan)}: #{server.flavor.name}"
        puts "#{h.color("Image", :cyan)}: #{server.image.name}"
        puts "#{h.color("Public DNS Name", :cyan)}: #{public_dns_name(server)}"
        puts "#{h.color("Public IP Address", :cyan)}: #{server.addresses["public"][0]}"
        puts "#{h.color("Private IP Address", :cyan)}: #{server.addresses["private"][0]}"
        puts "#{h.color("Password", :cyan)}: #{server.password}"
        puts "#{h.color("Run List", :cyan)}: #{@name_args.join(', ')}"
      end

      def bootstrap_for_node(server)
        bootstrap = Chef::Knife::Bootstrap.new
        bootstrap.name_args = [public_dns_name(server)]
        bootstrap.config[:run_list] = @name_args
        bootstrap.config[:ssh_user] = config[:ssh_user] || "root"
        bootstrap.config[:ssh_password] = server.password
        bootstrap.config[:identity_file] = config[:identity_file]
        bootstrap.config[:chef_node_name] = config[:chef_node_name] || server.id
        bootstrap.config[:prerelease] = config[:prerelease]
        bootstrap.config[:distro] = Chef::Config[:knife][:distro]
        # bootstrap will run as root...sudo (by default) also messes up Ohai on CentOS boxes
        bootstrap.config[:use_sudo] = config[:use_sudo]
        bootstrap.config[:template_file] = Chef::Config[:knife][:template_file]
        bootstrap.config[:environment] = config[:environment]
        bootstrap
      end

      def public_dns_name(server)
        @public_dns_name ||= begin
          Resolv.getname(server.addresses["public"][0])
        rescue
          "#{server.addresses["public"][0].gsub('.','-')}.static.cloud-ips.com"
        end
      end
    end
  end
end
