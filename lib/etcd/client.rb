require 'net/http'
require 'json'
require 'etcd/log'
require 'etcd/mixins/helpers'
require 'etcd/mixins/lockable'
require 'ostruct'


module Etcd
  ##
  # This is the central ruby class for Etcd. It provides methods for all Etcd api calls.
  # It also provides few additional methods beyond the core Etcd api, like Etcd::Client#lock
  # and Etcd::Client#eternal_watch, they are defined in separate modules and included in this
  # class
  class Client

    include Etcd::Helpers
    include Etcd::Lockable

    attr_reader :host, :port, :http, :allow_redirect, :use_ssl, :verify_mode

    ##
    # Creates a new instance of Etcd::Client. It accepts a hash +opts+ as argument
    # 
    # @param [Hash] opts The options for new Etcd::Client object
    # @opts [String] :host IP address of the etcd server (default is '127.0.0.1')
    # @opts [Fixnum] :port Port number of the etcd server (default is 4001)
    # @opts [Fixnum] :read_timeout Set default HTTP read timeout for all api calls (default is 60)

    def initialize(opts={})
      @host = opts[:host] || '127.0.0.1'
      @port = opts[:port] || 4001
      @read_timeout = opts[:read_timeout] || 60
      @allow_redirect = opts.has_key?(:allow_redirect) ? opts[:allow_redirect] : true
      @use_ssl = opts[:use_ssl] || false
      @verify_mode = opts[:verify_mode] || OpenSSL::SSL::VERIFY_PEER
    end

    # Currently use 'v2' as version for etcd store
    def version_prefix
      '/v2'
    end

    # Lists all machines in the cluster
    def machines
      api_execute( version_prefix + '/machines', :get).split(",").map(&:strip)
    end

    # Get the current leader in a cluster
    def leader
      api_execute( version_prefix + '/leader', :get)
    end

    # Lists all the data (keys, dir etc) present in etcd store
    def key_endpoint
      version_prefix + '/keys'
    end

    # Watches all keys and notifies if anyone changes
    def watch_endpoint
      version_prefix + '/watch'
    end

    # Set a new value for key if previous value of key is matched
    #
    # This method takes following parameters as argument
    # * key       - whose value is going to change if previous value is matched
    # * value     - new value to be set for specified key
    # * prevValue - value of a key to compare with existing value of key
    # * ttl       - shelf life of a key (in secsonds) (optional)
    def test_and_set(key, value, prevValue, ttl = nil)
      path  = key_endpoint + key
      payload = {'value' => value, 'prevValue' => prevValue }
      payload['ttl'] = ttl unless ttl.nil?
      response = api_execute(path, :put, params: payload)
      json2obj(response)
    end


    def create(key, value, ttl = nil)
      path  = key_endpoint + key
      payload = {value: value, prevExist: false }
      payload['ttl'] = ttl unless ttl.nil?
      response = api_execute(path, :put, params: payload)
      json2obj(response)
    end

    def update(key, value, ttl = nil)
      path  = key_endpoint + key
      payload = {value: value, prevExist: true }
      payload['ttl'] = ttl unless ttl.nil?
      response = api_execute(path, :put, params: payload)
      json2obj(response)
    end

    # Adds a new key with specified value and ttl, overwrites old values if exists
    #
    # This method has following parameters as argument
    # * key   - whose value to be set
    # * value - value to be set for specified key
    # * ttl   - shelf life of a key (in secsonds) (optional)
    def set(key, value, ttl=nil)
      path  = key_endpoint + key
      payload = {'value' => value}
      payload['ttl'] = ttl unless ttl.nil?
      response = api_execute(path, :put, params: payload)
      json2obj(response)
    end

    # Deletes a key along with all associated data
    #
    # This method has following parameters as argument
    # * key - key to be deleted
    def delete(key,opts={})
      response = api_execute(key_endpoint + key, :delete, params:opts)
      json2obj(response)
    end

    # Retrives a key with its associated data, if key is not present it will return with message "Key Not Found"
    #
    # This method has following parameters as argument
    # * key - whose data to be retrive
    def get(key, opts={})
      response = api_execute(key_endpoint + key, :get, params:opts)
      json2obj(response)
    end

    # Gives a notification when specified key changes
    #
    # This method has following parameters as argument
    # @ key   - key to be watched
    # @options [Hash] additional options for watching a key
    # @options [Fixnum] :index watch the specified key from given index
    # @options [Fixnum] :timeout specify http timeout (defaults to read_timeout value)
    def watch(key, options={})
      timeout = options[:timeout] || @read_timeout
      index = options[:waitIndex] || options[:index]
      response = if index.nil?
                    api_execute(key_endpoint + key, :get, timeout: timeout, params:{wait: true})
                  else
                    api_execute(key_endpoint + key, :get, timeout: timeout, params: {wait: true, waitIndex: index})
                  end
      json2obj(response)
    end

    # This method sends api request to etcd server.
    #
    # This method has following parameters as argument
    # * path    - etcd server path (etcd server end point)
    # * method  - the request method used
    # * options  - any additional parameters used by request method (optional)
    def api_execute(path, method, options={})

      params = options[:params]
      timeout = options[:timeout] || @read_timeout

      http = if path=~/^http/
                uri = URI.parse(path)
                path =  uri.path
                Net::HTTP.new(uri.host, uri.port)
              else
                Net::HTTP.new(host, port)
              end
      http.read_timeout = timeout
      http.use_ssl = use_ssl
      http.verify_mode = verify_mode

      case  method
      when :get
        unless params.nil?
          encoded_params = URI.encode_www_form(params)
          path+= "?" + encoded_params
        end
        req = Net::HTTP::Get.new(path)
      when :post
        encoded_params = URI.encode_www_form(params)
        req = Net::HTTP::Post.new(path)
        req.body= encoded_params
        Log.debug("Setting body for post '#{encoded_params}'")
      when :put
        encoded_params = URI.encode_www_form(params)
        req = Net::HTTP::Put.new(path)
        req.body= encoded_params
        Log.debug("Setting body for put '#{encoded_params}'")
      when :delete
        unless params.nil?
          encoded_params = URI.encode_www_form(params)
          path+= "?" + encoded_params
        end
        req = Net::HTTP::Delete.new(path)
      else
        raise "Unknown http action: #{method}"
      end

      Log.debug("Invoking: '#{req.class}' against '#{path}")
      res = http.request(req)
      Log.debug("Response code: #{res.code}")
      if res.is_a?(Net::HTTPSuccess)
        Log.debug("Http success")
        res.body
      elsif redirect?(res.code.to_i) and allow_redirect
        Log.debug("Http redirect, following")
        api_execute(res['location'], method, params: params)
      else
        Log.debug("Http error")
        Log.debug(res.body)
        res.error!
      end
    end

    private
    def redirect?(code)
      (code >= 300) and (code < 400)
    end

    def json2obj(json)
      obj = JSON.parse(json)
      if obj.has_key?('nodes')
        obj.map do |e|
          node2obj(e)
        end
      else
        node2obj(obj)
      end
    end

    def node2obj(hash)
      h = hash.dup
      h[:value] = h['node']['value'] if h.has_key?('node') and h['node'].has_key?('value')
      o = OpenStruct.new(h)
      o.node = OpenStruct.new(o.node) if h.has_key?('node')
      o
    end
  end
end
