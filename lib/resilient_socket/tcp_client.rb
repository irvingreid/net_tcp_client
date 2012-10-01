module ResilientSocket

  # Make Socket calls resilient by adding timeouts, retries and specific
  # exception categories
  #
  # Resilient TCP Client with:
  # * Connection Timeouts
  #   Ability to timeout if a connect does not complete within a reasonable time
  #   For example, this can occur when the server is turned off without shutting down
  #   causing clients to hang creating new connections
  #
  # * Automatic retries on startup connection failure
  #   For example, the server is being restarted while the client is starting
  #   Gives the server a few seconds to restart to
  #
  # * Automatic retries on active connection failures
  #   If the server is restarted during
  #
  # Connection and Read Timeouts are fully configurable
  #
  # Raises ConnectionTimeout when the connection timeout is exceeded
  # Raises ReadTimeout when the read timeout is exceeded
  # Raises ConnectionFailure when a network error occurs whilst reading or writing
  #
  # Future:
  #
  # * Automatic failover to another server should the current server not respond
  #   to a connection request by supplying an array of host names
  #
  class TCPClient
    # Supports embedding user supplied data along with this connection
    # such as sequence number, etc.
    # TCPClient will reset this value to nil on connection start and
    # after a connection is re-established. For example on automatic reconnect
    # due to a failed connection to the server
    attr_accessor :user_data

    # [String] Name of the server currently connected to or being connected to
    # including the port number
    #
    # Example:
    #   "localhost:2000"
    attr_reader :server

    # Create a connection, call the supplied block and close the connection on
    # completion of the block
    #
    # See #initialize for the list of parameters
    #
    # Example
    #   ResilientSocket::TCPClient.connect(
    #     :server                 => 'server:3300',
    #     :connect_retry_interval => 0.1,
    #     :connect_retry_count    => 5
    #   ) do |client|
    #     client.retry_on_connection_failure do
    #       client.send('Update the database')
    #     end
    #     response = client.read(20)
    #     puts "Received: #{response}"
    #   end
    #
    def self.connect(params={})
      begin
        connection = self.new(params)
        yield(connection)
      ensure
        connection.close if connection
      end
    end

    # Create a new TCP Client connection
    #
    # Parameters:
    #   :server [String]
    #     URL of the server to connect to with port number
    #     'localhost:2000'
    #
    #   :servers [Array of String]
    #     Array of URL's of servers to connect to with port numbers
    #     ['server1:2000', 'server2:2000']
    #
    #     The second server will only be attempted once the first server
    #     cannot be connected to or has timed out on connect
    #     A read failure or timeout will not result in switching to the second
    #     server, only a connection failure or during an automatic reconnect
    #
    #   :read_timeout [Float]
    #     Time in seconds to timeout on read
    #     Can be overridden by supplying a timeout in the read call
    #     Default: 60
    #
    #   :connect_timeout [Float]
    #     Time in seconds to timeout when trying to connect to the server
    #     Default: Half of the :read_timeout ( 30 seconds )
    #
    #   :log_level [Symbol]
    #     Only set this level to override the global SemanticLogger logging level
    #     Can be used to turn on trace or debug level logging in production
    #     Any valid SemanticLogger log level:
    #       :trace, :debug, :info, :warn, :error, :fatal
    #
    #   :buffered [Boolean]
    #     Whether to use Nagle's Buffering algorithm (http://en.wikipedia.org/wiki/Nagle's_algorithm)
    #     Recommend disabling for RPC style invocations where we don't want to wait for an
    #     ACK from the server before sending the last partial segment
    #     Buffering is recommended in a browser or file transfer style environment
    #     where multiple sends are expected during a single response
    #     Default: true
    #
    #   :connect_retry_count [Fixnum]
    #     Number of times to retry connecting when a connection fails
    #     Default: 10
    #
    #   :connect_retry_interval [Float]
    #     Number of seconds between connection retry attempts after the first failed attempt
    #     Default: 0.5
    #
    # Example
    #   client = ResilientSocket::TCPClient.new(
    #     :server                 => 'server:3300',
    #     :connect_retry_interval => 0.1,
    #     :connect_retry_count    => 5
    #   )
    #
    #   client.retry_on_connection_failure do
    #     client.send('Update the database')
    #   end
    #
    #   response = client.read(20)
    #   puts "Received: #{response}"
    #   client.close
    def initialize(parameters={})
      params = parameters.dup
      @read_timeout = (params.delete(:read_timeout) || 60.0).to_f
      @connect_timeout = (params.delete(:connect_timeout) || (@read_timeout/2)).to_f
      buffered = params.delete(:buffered)
      @buffered = buffered.nil? ? true : buffered
      @connect_retry_count = params.delete(:connect_retry_count) || 10
      @connect_retry_interval = (params.delete(:connect_retry_interval) || 0.5).to_f

      unless @servers = params[:servers]
        raise "Missing mandatory :server or :servers" unless server = params.delete(:server)
        @servers = [ server ]
      end
      @logger = SemanticLogger::Logger.new("#{self.class.name} #{@servers.inspect}", params[:log_level] || SemanticLogger::Logger.default_level)
      params.each_pair {|k,v| @logger.warn "Ignoring unknown option #{k} = #{v}"}

      # Connect to the Server
      connect
    end

    # Connect to the TCP server
    #
    # Raises ConnectionTimeout when the time taken to create a connection
    #        exceeds the :connect_timeout
    # Raises ConnectionFailure whenever Socket raises an error such as Error::EACCESS etc, see Socket#connect for more information
    #
    # Error handling is implemented as follows:
    # 1. TCP Socket Connect failure:
    #    Cannot reach server
    #    Server is being restarted, or is not running
    #    Retry 50 times every 100ms before raising a ConnectionFailure
    #    - Means all calls to #connect will take at least 5 seconds before failing if the server is not running
    #    - Allows hot restart of server process if it restarts within 5 seconds
    #
    # 2. TCP Socket Connect timeout:
    #    Timed out after 5 seconds trying to connect to the server
    #    Usually means server is busy or the remote server disappeared off the network recently
    #    No retry, just raise a ConnectionTimeout
    def connect
      retries = 0
      @logger.benchmark_info "Connected to server" do
        begin
          # TODO Implement failover to second server if connect fails
          @server = @servers.first

          host_name, port = @server.split(":")
          port = port.to_i
          address = Socket.getaddrinfo('localhost', nil, Socket::AF_INET)

          socket = Socket.new(Socket.const_get(address[0][0]), Socket::SOCK_STREAM, 0)
          socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1) unless @buffered

          # http://stackoverflow.com/questions/231647/how-do-i-set-the-socket-timeout-in-ruby
          begin
            socket_address = Socket.pack_sockaddr_in(port, address[0][3])
            socket.connect_nonblock(socket_address)
          rescue Errno::EINPROGRESS
            resp = IO.select(nil, [socket], nil, @connect_timeout)
            raise(ConnectionTimeout.new("Timedout after #{@connect_timeout} seconds trying to connect to #{host_name}:#{port}")) unless resp
            begin
              socket_address = Socket.pack_sockaddr_in(port, address[0][3])
              socket.connect_nonblock(socket_address)
            rescue Errno::EISCONN
            end
          end
          @socket = socket

        rescue SystemCallError => exception
          if retries < @connect_retry_count
            retries += 1
            @logger.warn "Connection failure: #{exception.class}: #{exception.message}. Retry: #{retries}"
            sleep @connect_retry_interval
            retry
          end
          @logger.error "Connection failure: #{exception.class}: #{exception.message}. Giving up after #{retries} retries"
          raise ConnectionFailure.new("After #{retries} attempts: #{exception.class}: #{exception.message}")
        end
      end
      self.user_data = nil
      true
    end

    # Send data to the server
    #
    # Use #with_retry to add resilience to the #send method
    #
    # Raises ConnectionFailure whenever the send fails
    #        For a description of the errors, see Socket#write
    #
    def send(data)
      @logger.trace("==> Sending", data)
      @logger.benchmark_debug("==> #send Sent #{data.length} bytes") do
        begin
          @socket.write(data)
        rescue SystemCallError => exception
          @logger.warn "#send Connection failure: #{exception.class}: #{exception.message}"
          close
          raise ConnectionFailure.new("Send Connection failure: #{exception.class}: #{exception.message}")
        end
      end
    end

    # Send data with retry logic
    #
    # On a connection failure, it will close the connection and retry the block
    # Returns immediately on exception ReadTimeout
    #
    # Note this method should only wrap a single standalone call to the server
    #      since it will automatically retry the entire block every time a
    #      connection failure is experienced
    #
    # Error handling is implemented as follows:
    #    Network failure during send of either the header or the body
    #    Since the entire message was not sent it is assumed that it will not be processed
    #    Close socket
    #    Retry 1 time using a new connection before raising a ConnectionFailure
    #
    # Example of a resilient request that could _modify_ data at the server:
    #
    # # Only the send is within the retry block since we cannot re-send once
    # # the send was successful
    #
    # Example of a resilient _read-only_ request:
    #
    # # Since the send can be sent many times it is safe to also put the receive
    # # inside the retry block
    #
    def retry_on_connection_failure
      retries = 0
      begin
        connect if closed?
        yield(self)
      rescue ConnectionFailure => exception
        close
        if retries < 3
          retries += 1
          @logger.warn "#retry_on_connection_failure Connection failure: #{exception.message}. Retry: #{retries}"
          connect
          retry
        end
        @logger.error "#retry_on_connection_failure Connection failure: #{exception.class}: #{exception.message}. Giving up after #{retries} retries"
        raise ConnectionFailure.new("After #{retries} retry_on_connection_failure attempts: #{exception.class}: #{exception.message}")
      rescue Exception => exc
        # With any other exception we have to close the connection since the connection
        # is now in an unknown state
        close
        raise exc
      end
    end

    # 4. TCP receive timeout:
    #    Send was successful but receive timed out after X seconds (for example 10 seconds)
    #    No data or partial data received ( for example header but no body )
    #    Close socket
    #    Don't retry since it could result in duplicating the request
    #    No retry, just raise a ReadTimeout
    #
    # Parameters
    #   maxlen [Fixnum]
    #     The Maximum number of bytes to return
    #     Very often less than maxlen bytes will be returned
    #
    #   timeout [Float]
    #     Optional: Override the default read timeout for this read
    #     Number of seconds before raising ReadTimeout when no data has
    #     been returned
    #     Default: :read_timeout supplied to #initialize
    def read(maxlen, buffer=nil, timeout=nil)
      buffer ||= ''
      @logger.benchmark_debug("<== #read Received upto #{maxlen} bytes") do
        # Block on data to read for @read_timeout seconds
        begin
          ready = IO.select([@socket], nil, [@socket], timeout || @read_timeout)
          unless ready
            @logger.warn "#read Timeout waiting for server to reply"
            close
            raise ReadTimeout.new("Timedout after #{timeout || @read_timeout} seconds trying to read from #{@server}")
          end
        rescue IOError => exception
          @logger.warn "#read Connection failure while waiting for data: #{exception.class}: #{exception.message}"
          close
          raise ConnectionFailure, "#{exception.class}: #{exception.message}"
        end

        # Read data from socket
        begin
          @socket.sysread(maxlen, buffer)
          @logger.trace("<== #read Received", buffer)
        rescue SystemCallError, IOError => exception
          @logger.warn "#read Connection failure while reading data: #{exception.class}: #{exception.message}"
          close
          raise ConnectionFailure, "#{exception.class}: #{exception.message}"
        end
      end
      buffer
    end

    # Close the socket
    #
    # Logs a warning if an error occurs trying to close the socket
    def close
      @socket.close unless @socket.closed?
    rescue IOError => exception
      @logger.warn "IOError when attempting to close socket: #{exception.class}: #{exception.message}"
    end

    # Returns whether the socket is closed
    def closed?
      @socket.closed?
    end

    # See: Socket#setsockopt
    def setsockopt(level, optname, optval)
      @socket.setsockopt(level, optname, optval)
    end

  end

end