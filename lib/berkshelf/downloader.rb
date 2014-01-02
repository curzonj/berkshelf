require 'net/http'
require 'zlib'
require 'archive/tar/minitar'

module Berkshelf
  class Downloader
    extend Forwardable

    attr_reader :berksfile

    def_delegators :berksfile, :sources

    # @param [Berkshelf::Berksfile] berksfile
    def initialize(berksfile)
      @berksfile = berksfile
    end

    # Download the given Berkshelf::Dependency.
    #
    # @param [String] name
    # @param [String] version
    #
    # @option options [String] :path
    #
    # @raise [CookbookNotFound]
    #
    # @return [String]
    def download(*args)
      options = args.last.is_a?(Hash) ? args.pop : Hash.new
      dependency, version = args

      if dependency.is_a?(Berkshelf::Dependency)
        dependency.download
      else
        sources.each do |source|
          if result = try_download(source, dependency, version)
            return result
          end
        end

        raise CookbookNotFound, "#{dependency} (#{version}) not found in any sources"
      end
    end

    # @param [Berkshelf::Source] source
    # @param [String] name
    # @param [String] version
    #
    # @return [String]
    def try_download(source, name, version)
      unless remote_cookbook = source.cookbook(name, version)
        return nil
      end

      case remote_cookbook.location_type
      when :opscode
        CommunityREST.new(remote_cookbook.location_path).download(name, version)
      when :chef_server
        # @todo Dynamically get credentials for remote_cookbook.location_path
        credentials = {
          server_url: remote_cookbook.location_path,
          client_name: Berkshelf::Config.instance.chef.node_name,
          client_key: Berkshelf::Config.instance.chef.client_key,
          ssl: {
            verify: Berkshelf::Config.instance.ssl.verify
          }
        }
        # @todo  Something scary going on here - getting an instance of Kitchen::Logger from test-kitchen
        # https://github.com/opscode/test-kitchen/blob/master/lib/kitchen.rb#L99
        Celluloid.logger = nil unless ENV["DEBUG_CELLULOID"]
        Ridley.open(credentials) { |r| r.cookbook.download(name, version) }
      when :github
        tmp_dir      = Dir.mktmpdir
        archive_path = File.join(tmp_dir, "#{name}-#{version}.tar.gz")
        out_dir      = File.join(tmp_dir, "#{name}-#{version}")
        url          = URI("https://codeload.github.com/#{remote_cookbook.location_path}/tar.gz/v#{version}")

        Net::HTTP.start(url.host, use_ssl: url.scheme == "https") do |http|
          resp = http.get(url.path)
          open(archive_path, "wb") { |file| file.write(resp.body) }
        end

        tgz = Zlib::GzipReader.new(File.open(archive_path, "rb"))
        Archive::Tar::Minitar.unpack(tgz, tmp_dir)

        out_dir
      else
        raise RuntimeError, "unknown location type #{remote_cookbook.location_type}"
      end
    rescue CookbookNotFound
      nil
    end
  end
end
