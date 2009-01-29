module CloudFiles

  class Connection
    # Authentication key provided when the CloudFiles class was instantiated
    attr_reader :authkey

    # Token returned after a successful authentication
    attr_accessor :authtoken

    # Authentication username provided when the CloudFiles class was instantiated
    attr_reader :authuser

    # Hostname of the CDN management server
    attr_accessor :cdnmgmthost

    # Path for managing containers on the CDN management server
    attr_accessor :cdnmgmtpath

    # Array of requests that have been made so far
    attr_reader :reqlog

    # Hostname of the storage server
    attr_accessor :storagehost

    # Path for managing containers/objects on the storage server
    attr_accessor :storagepath
    
    # Instance variable that is set when authorization succeeds
    attr_accessor :authok

    # Creates a new CloudFiles::Connection object.  Uses CloudFiles::Authentication to perform the login for the connection.
    # The authuser is the Mosso username, the authkey is the Mosso API key.
    #
    # This will likely be the base class for most operations.
    def initialize(authuser,authkey) 
      @authuser = authuser
      @authkey = authkey
      @authok = false
      @http = {}
      @reqlog = []
      CloudFiles::Authentication.new(self)
    end

    # Returns true if the authentication was successful and returns false otherwise.
    def authok?
      @authok
    end

    # Returns an CloudFiles::Container object that can be manipulated easily.  Throws a NoSuchContainerException if
    # the container doesn't exist.
    def container(name)
      CloudFiles::Container.new(self,name)
    end
    alias :get_container :container

    # Returns the cumulative size in bytes of all objects in all containers under the account.  Throws an
    # InvalidResponseException if the request fails.
    def bytes
      response = cfreq("HEAD",@storagehost,@storagepath)
      raise InvalidResponseException, "Unable to obtain account size" unless (response.code == "204")
      response["x-account-bytes-used"]
    end

    # Returns the number of containers present under the account as an integer. Throws an 
    # InvalidResponseException if the request fails.
    def count
      response = cfreq("HEAD",@storagehost,@storagepath)
      raise InvalidResponseException, "Unable to obtain container count" unless (response.code == "204")
      response["x-account-container-count"].to_i
    end

    # Gathers a list of the containers that exist for the account and returns the list of containers
    # as an array.  If no containers exist, an empty array is returned.  Throws an InvalidResponseException
    # if the request fails.
    def containers
      response = cfreq("GET",@storagehost,@storagepath)
      return [] if (response.code == "204")
      raise InvalidResponseException, "Invalid response code #{response.code}" unless (response.code == "200")
      response.body.to_a.map { |x| x.chomp }
    end
    alias :list_containers :containers

    # Retrieves a list of containers on the account along with their sizes (in bytes) and counts of the objects
    # held within them.  If no containers exist, an empty hash is returned.  Throws an InvalidResponseException
    # if the request fails.
    # 
    #   cf.containers_detail              #=> { "container1" => { :bytes => "36543", :count => "146" }, 
    #                                           "container2" => { :bytes => "105943", :count => "25" } }
    def containers_detail
      response = cfreq("GET",@storagehost,"#{@storagepath}?format=xml")
      return {} if (response.code == "204")
      raise InvalidResponseException, "Invalid response code #{response.code}" unless (response.code == "200")
      doc = REXML::Document.new(response.body)
      detailhash = {}
      doc.elements.each("account/container/") { |c|
        detailhash[c.elements["name"].text] = { :bytes => c.elements["bytes"].text, :count => c.elements["count"].text  }
      }
      doc = nil
      return detailhash
    end
    alias :list_containers_info :containers_detail

    # Returns true if the requested container exists and returns false otherwise.
    def container_exists?(containername)
      response = cfreq("HEAD",@storagehost,"#{@storagepath}/#{containername}")
      return (response.code == "204")? true : false ;
    end

    # Creates a new container and returns the CloudFiles::Container object.  Throws an InvalidResponseException if the 
    # request fails.
    #
    # Slash (/) and question mark (?) are invalid characters, and will be stripped out.  The container name is limited to 
    # 63 characters or less.
    def create_container(containername)
      containername.gsub!(/[\/\?]/,'')
      raise SyntaxException, "Container name is limited to 63 characters" if containername.size > 63
      response = cfreq("PUT",@storagehost,"#{@storagepath}/#{containername}")
      raise InvalidResponseException, "Unable to create container #{containername}" unless (response.code == "201" || response.code == "202")
      CloudFiles::Container.new(self,containername)
    end

    # Deletes a container from the account.  Throws a NonEmptyContainerException if the container still contains
    # objects.  Throws a NoSuchContainerException if the container doesn't exist.
    def delete_container(containername)
      response = cfreq("DELETE",@storagehost,"#{@storagepath}/#{containername}")
      raise NonEmptyContainerException, "Container #{containername} is not empty" if (response.code == "409")
      raise NoSuchContainerException, "Container #{containername} does not exist" unless (response.code == "204")
      true
    end

    # Gathers a list of public (CDN-enabled) containers that exist for an account and returns the list of containers
    # as an array.  If no containers are public, an empty array is returned.  Throws a InvalidResponseException if
    # the request fails.
    def public_containers
      response = cfreq("GET",@cdnmgmthost,@cdnmgmtpath)
      return [] if (response.code == "204")
      raise InvalidResponseException, "Invalid response code #{response.code}" unless (response.code == "200")
      response.body.to_a.map { |x| x.chomp }
    end

    def cfreq(method,server,path,headers = {},data = nil,&block) # :nodoc:
      start = Time.now
      hdrhash = headerprep(headers)
      path = URI.escape(path)
      start_http(server,path,headers)
      success = false
      count = 0
      until success == true
        begin
          request = Net::HTTP.const_get(method.to_s.capitalize).new(path,hdrhash)
          if data
            if data.respond_to?(:read)
              request.body_stream = data
            else
              request.body = data
            end
            request.content_length = data.respond_to?(:lstat) ? data.stat.size : data.size
          else
            request.content_length = 0
          end
          response = @http[server].request(request,block)
          success = true
        rescue Errno::EPIPE, Timeout::Error, Errno::EINVAL, EOFError
          # Server closed the connection, retry
          raise ConnectionException, "Unable to reconnect to #{server} after #{count} attempts" if count > 5
          count = count + 1
          success = false
          @http[server].finish
          start_http(server,path,headers)
        end
      end
      responsetime = "%0.3f" % (Time.now - start)
      @reqlog << "#{method} ".ljust(5)+"=> #{server}#{path} => #{response.code} => #{responsetime}s"
      response
    end
    
    private
    
    def headerprep(headers = {}) # :nodoc:
      default_headers = {}
      default_headers["X-Auth-Token"] = @authtoken if (authok? && @account.nil?)
      default_headers["X-Storage-Token"] = @authtoken if (authok? && !@account.nil?)
      default_headers["Connection"] = "Keep-Alive"
      default_headers["User-Agent"] = "CloudFiles Ruby API"
      default_headers.merge(headers)
    end
    
    def start_http(server,path,headers) # :nodoc:
      if (@http[server].nil?)
        begin
          @http[server] = Net::HTTP.new(server,443)
          @http[server].use_ssl = true
          @http[server].verify_mode = OpenSSL::SSL::VERIFY_NONE
          @http[server].start
        rescue
          raise ConnectionException, "Unable to connect to #{server}"
        end
      end
    end

  end

end