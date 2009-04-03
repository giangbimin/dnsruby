#--
#Copyright 2007 Nominet UK
#
#Licensed under the Apache License, Version 2.0 (the "License");
#you may not use this file except in compliance with the License. 
#You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0 
#
#Unless required by applicable law or agreed to in writing, software 
#distributed under the License is distributed on an "AS IS" BASIS, 
#WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
#See the License for the specific language governing permissions and 
#limitations under the License.
#++
#require "Dnsruby/resolver_register.rb"
require "Dnsruby/InternalResolver"
require "Dnsruby/Recursor"
module Dnsruby
  #== Description
  #Dnsruby::Resolver is a DNS stub resolver.
  #This class uses a set of SingleResolvers to perform queries with retries across multiple nameservers.
  #
  #The retry policy is a combination of the Net::DNS and dnsjava approach, and has the option of :
  #* A total timeout for the query (defaults to 0, meaning "no total timeout")
  #* A retransmission system that targets the namervers concurrently once the first query round is 
  #  complete, but in which the total time per query round is split between the number of nameservers 
  #  targetted for the first round. and total time for query round is doubled for each query round
  #   
  # Note that, if a total timeout is specified, then that will apply regardless of the retry policy 
  #(i.e. it may cut retries short).
  #  
  # Note also that these timeouts are distinct from the SingleResolver's packet_timeout
  #
  #== Methods
  # 
  #=== Synchronous
  #These methods raise an exception or return a response message with rcode==NOERROR
  #
  #*  Dnsruby::Resolver#send_message(msg)
  #*  Dnsruby::Resolver#query(name [, type [, klass]])
  #
  #=== Asynchronous
  #These methods use a response queue to return the response and the error
  #
  #*  Dnsruby::Resolver#send_async(msg, response_queue, query_id)
  #
  #== Event Loop
  #Dnsruby runs a pure Ruby event loop to handle I/O in a single thread.
  #Support for EventMachine has been deprecated.
  class Resolver
    DefaultQueryTimeout = 0 
    DefaultPacketTimeout = 10
    DefaultRetryTimes = 4
    DefaultRetryDelay = 5
    DefaultPort = 53
    DefaultDnssec = true
    AbsoluteMinDnssecUdpSize = 1220
    MinDnssecUdpSize = 4096
    DefaultUDPSize = MinDnssecUdpSize

    class EventType
      RECEIVED = 0 
      VALIDATED = 1 # @TODO@ Should be COMPLETE?
      ERROR = 2
    end

    # The port to send queries to on the resolver
    attr_reader :port
    
    # Should TCP be used as a transport rather than UDP?
    attr_reader :use_tcp
    
    
    attr_reader :tsig
    
    # Should truncation be ignored?
    # i.e. the TC bit is ignored and thus the resolver will not requery over TCP if TC is set
    attr_reader :ignore_truncation
    
    # The source address to send queries from
    attr_reader :src_address
    
    # Should TCP queries be sent on a persistent socket?
    attr_reader :persistent_tcp
    # Should UDP queries be sent on a persistent socket?
    attr_reader :persistent_udp
    
    # Should the Recursion Desired bit be set?
    attr_reader :recurse
    
    # The maximum UDP size to be used
    attr_reader :udp_size
    
    # The current Config
    attr_reader :config
    
    # The array of SingleResolvers used for sending query messages
    attr_accessor :single_resolvers # :nodoc:
    
    #The timeout for any individual packet. This is the timeout used by SingleResolver
    attr_reader :packet_timeout
    
    # Note that this timeout represents the total time a query may run for - multiple packets
    # can be sent to multiple nameservers in this time.
    # This is distinct from the SingleResolver per-packet timeout
    # The query_timeout is not required - it will default to 0, which means "do not use query_timeout".
    # If this is the case then the timeout will be dictated by the retry_times and retry_delay attributes
    attr_accessor :query_timeout
    
    # The query will be tried across nameservers retry_times times, with a delay of retry_delay seconds
    # between each retry. The first time round, retry_delay will be divided by the number of nameservers
    # being targetted, and a new nameserver will be queried with the resultant delay.
    attr_accessor :retry_times, :retry_delay
    
    # Use DNSSEC for this Resolver
    attr_reader :dnssec
    
    #--
    #@TODO@ add load_balance? i.e. Target nameservers in a random, rather than pre-determined, order?
    #This is best done when configuring the Resolver, as it will re-order servers based on their response times.
    #
    #++
    
    # Query for a name. If a valid Message is received, then it is returned
    # to the caller. Otherwise an exception (a Dnsruby::ResolvError or Dnsruby::ResolvTimeout) is raised.
    #
    #   require 'Dnsruby'
    #   res = Dnsruby::Resolver.new
    #   response = res.query("example.com") # defaults to Types.A, Classes.IN
    #   response = res.query("example.com", Types.MX)
    #   response = res.query("208.77.188.166") # IPv4 address so PTR query will be made
    #   response = res.query("208.77.188.166", Types.PTR)
    def query(name, type=Types.A, klass=Classes.IN, set_cd=@dnssec)
      msg = Message.new
      msg.header.rd = 1
      msg.add_question(name, type, klass)
      if (@dnssec)
        msg.header.cd = set_cd # We do our own validation by default
      end
      return send_message(msg)
    end
    
    # Send a message, and wait for the response. If a valid Message is received, then it is returned 
    # to the caller. Otherwise an exception (a Dnsruby::ResolvError or Dnsruby::ResolvTimeout) is raised.
    # 
    # send_async is called internally.
    # 
    # example :
    # 
    #   require 'Dnsruby'
    #   res = Dnsruby::Resolver.new
    #   begin
    #   response = res.send_message(Message.new("example.com", Types.MX))
    #   rescue ResolvError
    #     # ...
    #   rescue ResolvTimeout
    #     # ...
    #   end
    def send_message(message)
      Dnsruby.log.debug{"Resolver : sending message"}
      q = Queue.new
      send_async(message, q)
      #      # @TODO@ Add new queue tuples, e.g. :
      #      event_type = EventType::RECEIVED
      #      reply = nil
      #      while (event_type == EventType::RECEIVED)
      #        id, event_type, reply, error = q.pop
      #        Dnsruby.log.debug{"Resolver : result received"}
      #        if ((error != nil) && (event_type == EventType::ERROR))
      #          raise error
      #        end
      #        print "Reply = #{reply}\n"
      #      end
      #      print "Reply = #{reply}\n"
      #      return reply


      id, result, error = q.pop
      if (error != nil)
        raise error
      else
        return result
      end
    end
    
    
    #Asynchronously send a Message to the server. The send can be done using just
    #Dnsruby. Support for EventMachine has been deprecated.
    # 
    #== Dnsruby pure Ruby event loop :
    # 
    #A client_queue is supplied by the client, 
    #along with an optional client_query_id to identify the response. The client_query_id
    #is generated, if not supplied, and returned to the client.
    #When the response is known, 
    #a tuple of (query_id, response_message, exception) will be added to the client_queue.
    # 
    #The query is sent synchronously in the caller's thread. The select thread is then used to 
    #listen for and process the response (up to pushing it to the client_queue). The client thread 
    #is then used to retrieve the response and deal with it.
    # 
    #Takes :
    # 
    #* msg - the message to send
    #* client_queue - a Queue to push the response to, when it arrives
    #* client_query_id - an optional ID to identify the query to the client
    #* use_tcp - whether to use TCP (defaults to SingleResolver.use_tcp)
    #
    #Returns :
    # 
    #* client_query_id - to identify the query response to the client. This ID is
    #generated if it is not passed in by the client
    # 
    #=== Example invocations :
    #
    #    id = res.send_async(msg, queue)
    #    NOT SUPPORTED : id = res.send_async(msg, queue, use_tcp)
    #    id = res.send_async(msg, queue, id)
    #    id = res.send_async(msg, queue, id, use_tcp)
    #    
    #=== Example code :
    #
    #   require 'Dnsruby'
    #   res = Dnsruby::Resolver.newsend
    #   query_id = 10 # can be any object you like
    #   query_queue = Queue.new
    #   res.send_async(Message.new("example.com", Types.MX),  query_queue, query_id)
    #   query_id_2 = res.send_async(Message.new("example.com", Types.A), query_queue)
    #   # ...do a load of other stuff here...
    #   2.times do 
    #     response_id, response, exception = query_queue.pop
    #     # You can check the ID to see which query has been answered
    #     if (exception == nil)
    #         # deal with good response
    #     else
    #         # deal with problem
    #     end
    #   end
    #
    def send_async(*args) # msg, client_queue, client_query_id)
      if (!@resolver_ruby) # @TODO@ Synchronize this?
        @resolver_ruby = ResolverRuby.new(self)
      end
      return @resolver_ruby.send_async(*args)
    end
    
    # Close the Resolver. Unfinished queries are terminated with OtherResolvError.
    def close
      @resolver_ruby.close if @resolver_ruby
    end
    
    # Create a new Resolver object. If no parameters are passed in, then the default 
    # system configuration will be used. Otherwise, a Hash may be passed in with the 
    # following optional elements : 
    # 
    # 
    # * :port
    # * :use_tcp
    # * :tsig
    # * :ignore_truncation
    # * :src_address
    # * :src_port
    # * :persistent_tcp
    # * :persistent_udp
    # * :recurse
    # * :udp_size
    # * :config_info - see Config
    # * :nameserver - can be either a String or an array of Strings
    # * :packet_timeout
    # * :query_timeout
    # * :retry_times
    # * :retry_delay
    def initialize(*args)
      # @TODO@ Should we allow :namesver to be an RRSet of NS records? Would then need to randomly order them?
      @resolver_ruby = nil
      @src_address = nil
      reset_attributes
      
      # Process args
      if (args.length==1)
        if (args[0].class == Hash)
          args[0].keys.each do |key|
            begin
              if (key == :config_info)
                @config.set_config_info(args[0][:config_info])
              elsif (key==:nameserver)
                set_config_nameserver(args[0][:nameserver])
              else
                send(key.to_s+"=", args[0][key])
              end
            rescue Exception
              Dnsruby.log.error{"Argument #{key} not valid\n"}
            end
          end
        elsif (args[0].class == String)
          set_config_nameserver(args[0])          
        elsif (args[0].class == Config)
          # also accepts a Config object from Dnsruby::Resolv
          @config = args[0]
        end
      else
        # Anything to do?
      end
      if (@single_resolvers==[])
        add_config_nameservers
      end
      update
      #      ResolverRegister::register_resolver(self)
    end
    
    def add_config_nameservers # :nodoc: all
      # Add the Config nameservers
      @config.nameserver.each do |ns|
        @single_resolvers.push(InternalResolver.new({:server=>ns, :dnssec=>@dnssec,
              :use_tcp=>@use_tcp, :packet_timeout=>@packet_timeout,
              :tsig => @tsig, :ignore_truncation=>@ignore_truncation,
              :src_address=>@src_address, :src_port=>@src_port,
              :recurse=>@recurse, :udp_size=>@udp_size}))
      end
    end
    
    def set_config_nameserver(n)
      # @TODO@ Should we allow NS RRSet here? If so, then .sort_by {rand}
      if (n).kind_of?String
        @config.nameserver=[n]
      else
        @config.nameserver=n
      end
    end    
    
    def reset_attributes #:nodoc: all
      if (@resolver_ruby)
        @resolver_ruby.reset_attributes
      end
     
      # Attributes
      @query_timeout = DefaultQueryTimeout
      @retry_delay = DefaultRetryDelay
      @retry_times = DefaultRetryTimes
      @packet_timeout = DefaultPacketTimeout
      @port = DefaultPort
      @udp_size = DefaultUDPSize
      @dnssec = DefaultDnssec
      @use_tcp = false
      @tsig = nil
      @ignore_truncation = false
      @config = Config.new()
      @src_address        = '0.0.0.0'
      @src_port        = [0]
      @recurse = true
      @persistent_udp = false
      @persistent_tcp = false
      @single_resolvers=[]
    end
    
    def update #:nodoc: all
      #Update any resolvers we have with the latest config
      @single_resolvers.each do |res|
        [:port, :use_tcp, :tsig, :ignore_truncation, :packet_timeout, 
          :src_address, :src_port, :persistent_tcp, :persistent_udp, :recurse, 
          :udp_size, :dnssec].each do |param|
          
          res.send(param.to_s+"=", instance_variable_get("@"+param.to_s))
        end
      end
    end
    
    #    # Add a new SingleResolver to the list of resolvers this Resolver object will
    #    # query.
    #    def add_resolver(internal) # :nodoc:
    #      # @TODO@ Make a new InternalResolver from this SingleResolver!!
    #      @single_resolvers.push(internal)
    #    end

    def add_server(server)
      res = InternalResolver.new(server)
      [:port, :use_tcp, :tsig, :ignore_truncation, :packet_timeout,
        :src_address, :src_port, :persistent_tcp, :persistent_udp, :recurse,
        :udp_size, :dnssec].each do |param|
          
        res.send(param.to_s+"=", instance_variable_get("@"+param.to_s))
      end
      @single_resolvers.push(res)
    end
    
    def nameserver=(n)
      @single_resolvers=[]
      set_config_nameserver(n)
      add_config_nameservers
    end
    
    #--
    #@TODO@ Should really auto-generate these methods.
    #Also, any way to tie them up with SingleResolver RDoc?
    #++
    
    def packet_timeout=(t)
      @packet_timeout = t
      update
    end
    
    # The source port to send queries from
    # Returns either a single Fixnum or an Array
    # e.g. "0", or "[60001, 60002, 60007]"
    # 
    # Defaults to 0 - random port
    def src_port
      if (@src_port.length == 1) 
        return @src_port[0]
      end
      return @src_port
    end

    # Can be a single Fixnum or a Range or an Array
    # If an invalid port is selected (one reserved by
    # IANA), then an ArgumentError will be raised.
    # 
    #        res.src_port=0
    #        res.src_port=[60001,60005,60010]
    #        res.src_port=60015..60115
    #
    def src_port=(p)
      if (Resolver.check_port(p))
        @src_port = Resolver.get_ports_from(p)
        update
      end
    end
    
    # Can be a single Fixnum or a Range or an Array
    # If an invalid port is selected (one reserved by
    # IANA), then an ArgumentError will be raised.
    # "0" means "any valid port" - this is only a viable
    # option if it is the only port in the list.
    # An ArgumentError will be raised if "0" is added to
    # an existing set of source ports.
    # 
    #        res.add_src_port(60000)
    #        res.add_src_port([60001,60005,60010])
    #        res.add_src_port(60015..60115)
    #
    def add_src_port(p)
      if (Resolver.check_port(p, @src_port))
        a = Resolver.get_ports_from(p)
        a.each do |x|
          if ((@src_port.length > 0) && (x == 0))
            raise ArgumentError.new("src_port of 0 only allowed as only src_port value (currently #{@src_port.length} values")
          end
          @src_port.push(x)
        end
      end
      update
    end

    def Resolver.check_port(p, src_port=[])
      if (p.class != Fixnum)
        tmp_src_ports = Array.new(src_port)
        p.each do |x|
          if (!Resolver.check_port(x, tmp_src_ports))
            return false
          end
          tmp_src_ports.push(x)
        end
        return true
      end
      if (Resolver.port_in_range(p))
        if ((p == 0) && (src_port.length > 0))
          return false
        end
        return true
      else
        Dnsruby.log.error("Illegal port (#{p})")
        raise ArgumentError.new("Illegal port #{p}")
      end
    end

    def Resolver.port_in_range(p)
      if ((p == 0) || ((IANA_PORTS.index(p)) == nil &&
              (p > 1024) && (p < 65535)))
        return true
      end
      return false
    end

    def Resolver.get_ports_from(p)
      a = []
      if (p.class == Fixnum)
        a = [p]
      else
        p.each do |x|
          a.push(x)
        end
      end
      return a
    end

    def use_tcp=(on)
      @use_tcp = on
      update
    end
    
    #Sets the TSIG to sign outgoing messages with.
    #Pass in either a Dnsruby::RR::TSIG, or a key_name and key (or just a key)
    #Pass in nil to stop tsig signing.
    #* res.tsig=(tsig_rr)
    #* res.tsig=(key_name, key)
    #* res.tsig=nil # Stop the resolver from signing
    def tsig=(t)
      @tsig=t
      update
    end

    def Resolver.get_tsig(args)
      tsig = nil
      if (args.length == 1)
        if (args[0])
          if (args[0].instance_of?RR::TSIG)
            tsig = args[0]
          elsif (args[0].instance_of?Array)
            tsig = RR.new_from_hash({:type => Types.TSIG, :klass => Classes.ANY, :name => args[0][0], :key => args[0][1]})
          end
        else
          #          Dnsruby.log.debug{"TSIG signing switched off"}
          return nil
        end
      elsif (args.length ==2)
        tsig = RR.new_from_hash({:type => Types.TSIG, :klass => Classes.ANY, :name => args[0], :key => args[1]})
      else
        raise ArgumentError.new("Wrong number of arguments to tsig=")
      end
      Dnsruby.log.info{"TSIG signing now using #{tsig.name}, key=#{tsig.key}"}
      return tsig
    end

    
    def ignore_truncation=(on)
      @ignore_truncation = on
      update
    end
    
    def src_address=(a)
      @src_address = a
      update
    end
    
    def port=(a)
      @port = a
      update
    end
    
    def persistent_tcp=(on)
      @persistent_tcp = on
      update
    end
    
    def persistent_udp=(on)
      @persistent_udp = on
      update
    end
    
    def recurse=(a)
      @recurse = a
      update
    end
    
    def dnssec=(d)
      @dnssec = d
      if (d)
        # Set the UDP size (RFC 4035 section 4.1)
        if (@udp_size < MinDnssecUdpSize)
          self.udp_size = MinDnssecUdpSize
        end
      end
      update
    end
    
    def udp_size=(s)
      @udp_size = s
      update
    end

    def generate_timeouts(base=0) #:nodoc: all
      #These should be be pegged to the single_resolver they are targetting :
      #  e.g. timeouts[timeout1]=nameserver
      timeouts = {}
      retry_delay = @retry_delay
      @retry_times.times do |retry_count|
        if (retry_count>0)
          retry_delay *= 2
        end
        servers=[]
        @single_resolvers.each do |r| servers.push(r.server) end
        @single_resolvers.each_index do |i|
          res= @single_resolvers[i]
          offset = (i*@retry_delay.to_f/@single_resolvers.length)
          if (retry_count==0)
            timeouts[base+offset]=[res, retry_count]
          else
            if (timeouts.has_key?(base+retry_delay+offset))
              Dnsruby.log.error{"Duplicate timeout key!"}
              raise RuntimeError.new("Duplicate timeout key!")
            end
            timeouts[base+retry_delay+offset]=[res, retry_count]
          end
        end
      end
      return timeouts      
    end
  end
  

  # This class implements the I/O using pure Ruby, with no dependencies.
  # Support for EventMachine has been deprecated.
  class ResolverRuby #:nodoc: all
    def initialize(parent)
      reset_attributes
      @parent=parent
    end
    def reset_attributes #:nodoc: all
      # data structures
      @mutex=Mutex.new
      @query_list = {}
      @timeouts = {}
    end
    def send_async(*args) # msg, client_queue, client_query_id=nil)
      msg=args[0]
      client_queue=nil
      client_query_id=nil
      client_queue=args[1]
      if (args.length > 2)
        client_query_id = args[2]
      end

      
      # This is the whole point of the Resolver class.
      # We want to use multiple SingleResolvers to run a query.
      # So we kick off a system with select_thread where we send
      # a query with a queue, but log ourselves as observers for that
      # queue. When a new response is pushed on to the queue, then the
      # select thread will call this class' handler method IN THAT THREAD.
      # When the final response is known, this class then sticks it in
      # to the client queue.
      
      q = Queue.new
      if (client_query_id==nil)
        client_query_id = Time.now + rand(10000)
      end
      
      if (!client_queue.kind_of?Queue)
        Dnsruby.log.error{"Wrong type for client_queue in Resolver#send_async"}
        # @TODO@ Handle different queue tuples - push this to generic send_error method
        client_queue.push([client_query_id, ArgumentError.new("Wrong type of client_queue passed to Dnsruby::Resolver#send_async - should have been Queue, was #{client_queue.class}")])
        return
      end
      
      if (!msg.kind_of?Message)
        Dnsruby.log.error{"Wrong type for msg in Resolver#send_async"}
        # @TODO@ Handle different queue tuples - push this to generic send_error method
        client_queue.push([client_query_id, ArgumentError.new("Wrong type of msg passed to Dnsruby::Resolver#send_async - should have been Message, was #{msg.class}")])
        return
      end
      
      tick_needed=false
      # add to our data structures
      @mutex.synchronize{
        tick_needed = true if @query_list.empty?
        if (@query_list.has_key?client_query_id)
          Dnsruby.log.error{"Duplicate query id requested (#{client_query_id}"}
          # @TODO@ Handle different queue tuples - push this to generic send_error method
          client_queue.push([client_query_id, ArgumentError.new("Client query ID already in use")])
          return
        end
        outstanding = []
        @query_list[client_query_id]=[msg, client_queue, q, outstanding]
        
        query_timeout = Time.now+@parent.query_timeout
        if (@parent.query_timeout == 0)
          query_timeout = Time.now+31536000 # a year from now
        end
        @timeouts[client_query_id]=[query_timeout, generate_timeouts()]
      }
      
      # Now do querying stuff using SingleResolver
      # All this will be handled by the tick method (if we have 0 as the first timeout)
      st = SelectThread.instance
      st.add_observer(q, self)
      tick if tick_needed
      return client_query_id
    end
    
    def generate_timeouts() #:nodoc: all
      # Create the timeouts for the query from the retry_times and retry_delay attributes. 
      # These are created at the same time in case the parameters change during the life of the query.
      # 
      # These should be absolute, rather than relative
      # The first value should be Time.now[      
      time_now = Time.now
      timeouts=@parent.generate_timeouts(time_now)
      return timeouts
    end
    
    # Close the Resolver. Unfinished queries are terminated with OtherResolvError.
    def close
      @mutex.synchronize {
        @query_list.each do |client_query_id, values|
          msg, client_queue, q, outstanding = values
          send_result_and_close(client_queue, client_query_id, q, nil, OtherResolvError.new("Resolver closing!"))
        end
      }
    end
    
    # MUST BE CALLED IN A SYNCHRONIZED BLOCK!    
    # 
    # Send the result back to the client, and close the socket for that query by removing 
    # the query from the select thread.
    def send_result_and_stop_querying(client_queue, client_query_id, select_queue, msg, error) #:nodoc: all
      stop_querying(client_query_id)
      send_result(client_queue, client_query_id, select_queue, msg, error)
    end

    # MUST BE CALLED IN A SYNCHRONIZED BLOCK!
    #
    # Stops send any more packets for a client-level query
    def stop_querying(client_query_id) #:nodoc: all
      @timeouts.delete(client_query_id) 
    end

    # MUST BE CALLED IN A SYNCHRONIZED BLOCK!
    #
    # Sends the result to the client's queue, and removes the queue observer from the select thread
    def send_result(client_queue, client_query_id, select_queue, msg, error) #:nodoc: all
      stop_querying(client_query_id)  # @TODO@ !
      # We might still get some callbacks, which we should ignore
      st = SelectThread.instance
      st.remove_observer(select_queue, self)
      #      @mutex.synchronize{
      # Remove the query from all of the data structures
      @query_list.delete(client_query_id)
      #      }
      # Return the response to the client
      if (error != nil)
        #        client_queue.push([client_query_id, Resolver::EventType::ERROR, msg, error])
        client_queue.push([client_query_id, msg, error])
      else
        #        client_queue.push([client_query_id, Resolver::EventType::VALIDATED, msg, error])
        client_queue.push([client_query_id, msg, error])
      end
    end
    
    # This method is called twice a second from the select loop, in the select thread.
    # It should arguably be called from another worker thread... (which also handles the queue)
    # Each tick, we check if any timeouts have occurred. If so, we take the appropriate action : 
    # Return a timeout to the client, or send a new query
    def tick #:nodoc: all
      # Handle the tick
      # Do we have any retries due to be sent yet?
      @mutex.synchronize{
        time_now = Time.now
        @timeouts.keys.each do |client_query_id|
          msg, client_queue, select_queue, outstanding = @query_list[client_query_id]
          query_timeout, timeouts = @timeouts[client_query_id]
          if (query_timeout < Time.now)
            #Time the query out
            send_result_and_stop_querying(client_queue, client_query_id, select_queue, nil, ResolvTimeout.new("Query timed out"))
            next
          end
          timeouts_done = []
          timeouts.keys.sort.each do |timeout|
            if (timeout < time_now)
              # Send the next query
              res, retry_count = timeouts[timeout]
              id = [res, msg, client_query_id, retry_count]
              Dnsruby.log.debug{"Sending msg to #{res.server}"}
              # We should keep a list of the queries which are outstanding
              outstanding.push(id)
              timeouts_done.push(timeout)
              timeouts.delete(timeout)

              # Pick a new QID here
              new_msg = msg # .dup(); # @TODO@
              new_msg.header = msg.header.dup();
              new_msg.header.id = rand(65535);
              #              print "New query : #{new_msg}\n"
              res.send_async(new_msg, select_queue, id)
            else
              break
            end
          end
          timeouts_done.each do |t|
            timeouts.delete(t)
          end
        end
      }
    end
    
    # This method is called by the SelectThread (in the select thread) when the queue has a new item on it.
    # The queue interface is used to separate producer/consumer threads, but we're using it here in one thread. 
    # It's probably a good idea to create a new "worker thread" to take items from the select thread queue and 
    # call this method in the worker thread.
    # 
    def handle_queue_event(queue, id) #:nodoc: all
      # Time to process a new queue event.
      # If we get a callback for an ID we don't know about, don't worry -
      # just ignore it. It may be for a query we've already completed.
      # 
      # So, get the next response from the queue (presuming there is one!)
      #
      # @TODO@ Tick could poll the queue and then call this method if needed - no need for observer interface.
      # @TODO@ Currently, tick and handle_queue_event called from select_thread - could have thread chuck events in to tick_queue. But then, clients would have to call in on other thread!
      #
      # So - two types of response :
      # 1) we've got a coherent response (or error) - stop sending more packets for that query!
      # 2) we've validated the response - it's ready to be sent to the client
      #
      # so need two more methods :
      #  handleValidationResponse : basically calls send_result_and_close and
      #  handleValidationError : does the same as handleValidationResponse, but for errors
      # can leave handleError alone
      # but need to change handleResponse to stop sending, rather than send_result_and_close.
      #
      # @TODO@ Also, we could really do with a MaxValidationTimeout - if validation not OK within
      # this time, then raise Timeout (and stop validation)?
      #
      # @TODO@ Also, should there be some facility to stop validator following same chain
      # concurrently?
      #
      # @TODO@ Also, should have option to speak only to configured resolvers (not follow authoritative chain)
      #
      if (queue.empty?)
        Dnsruby.log.fatal{"Queue empty in handle_queue_event!"}
        raise RuntimeError.new("Severe internal error - Queue empty in handle_queue_event")
      end
      event_id, event_type, response, error = queue.pop
      # We should remove this packet from the list of outstanding packets for this query
      resolver, msg, client_query_id, retry_count = id
      if (id != event_id)
        Dnsruby.log.error{"Serious internal error!! #{id} expected, #{event_id} received"}
        raise RuntimeError.new("Serious internal error!! #{id} expected, #{event_id} received")
      end
      @mutex.synchronize{
        if (@query_list[client_query_id]==nil)
          #          print "Dead query response - ignoring\n"
          Dnsruby.log.debug{"Ignoring response for dead query"}
          return
        end
        msg, client_queue, select_queue, outstanding = @query_list[client_query_id]
        if (event_type == Resolver::EventType::RECEIVED)
          if (!outstanding.include?id)
            Dnsruby.log.error{"Query id not on outstanding list! #{outstanding.length} items. #{id} not on #{outstanding}"}
            raise RuntimeError.new("Query id not on outstanding!")
          end
          outstanding.delete(id)
        end
        #      }
        if (event_type == Resolver::EventType::RECEIVED)
          #      if (event.kind_of?(Exception))
          if (error != nil)
            handle_error_response(queue, event_id, error, response)
          else # if (event.kind_of?(Message))
            handle_response(queue, event_id, response)
            #      else
            #        Dnsruby.log.error("Random object #{event.class} returned through queue to Resolver")
          end
        elsif (event_type == Resolver::EventType::VALIDATED)
          if (error != nil)
            handle_validation_error(queue, event_id, error, response)
          else
            handle_validation_response(queue, event_id, response)
          end
        elsif (event_type == Resolver::EventType::ERROR)
          handle_error_response(queue, event_id, error, response)
        else
          #          print "ERROR - UNKNOWN EVENT TYPE IN RESOLVER : #{event_type}\n"
          TheLog.error("ERROR - UNKNOWN EVENT TYPE IN RESOLVER : #{event_type}")
        end
      }
    end
    
    def handle_error_response(select_queue, query_id, error, response) #:nodoc: all
      #Handle an error
      #      @mutex.synchronize{
      Dnsruby.log.debug{"handling error #{error.class}, #{error}"}
      # Check what sort of error it was :
      resolver, msg, client_query_id, retry_count = query_id
      msg, client_queue, select_queue, outstanding = @query_list[client_query_id]
      if (error.kind_of?(ResolvTimeout))
        #   - if it was a timeout, then check which number it was, and how many retries are expected on that server
        #       - if it was the last retry, on the last server, then return a timeout to the client (and clean up)
        #       - otherwise, continue
        # Do we have any more packets to send to this resolver?

        decrement_resolver_priority(resolver)
        timeouts = @timeouts[client_query_id]
        if (outstanding.empty? && timeouts[1].values.empty?)
          Dnsruby.log.debug{"Sending timeout to client"}
          send_result_and_stop_querying(client_queue, client_query_id, select_queue, response, error)
        end
      elsif (error.kind_of?NXDomain)
        #   - if it was an NXDomain, then return that to the client, and stop all new queries (and clean up)
        send_result_and_stop_querying(client_queue, client_query_id, select_queue, response, error)
      else
        #   - if it was any other error, then remove that server from the list for that query
        #   If a Too Many Open Files error, then don't remove, but let retry work.
        timeouts = @timeouts[client_query_id]
        if (!(error.to_s=~/Errno::EMFILE/))
          # @TODO@ Should we also stick it to the back of the list for future queries?
          Dnsruby.log.debug{"Removing #{resolver.server} from resolver list for this query"}
          timeouts[1].each do |key, value|
            res = value[0]
            if (res == resolver)
              timeouts[1].delete(key)
            end
          end
          demote_resolver(resolver)
        else
          Dnsruby.log.debug{"NOT Removing #{resolver.server} due to Errno::EMFILE"}
        end
        #        - if it was the last server, then return an error to the client (and clean up)
        if (outstanding.empty? && timeouts[1].values.empty?)
          #          if (outstanding.empty?)
          Dnsruby.log.debug{"Sending error to client"}
          send_result_and_stop_querying(client_queue, client_query_id, select_queue, response, error)
        end
      end
      #@TODO@ If we're still sending packets for this query, but none are outstanding, then
      #jumpstart the next query?
      #      }
    end

    # TO BE CALLED IN A SYNCHRONIZED BLOCK
    def increment_resolver_priority(res)
      TheLog.debug("Incrementing resolver priority for #{res.server}\n")
      index = @parent.single_resolvers.index(res)
      if (index > 0)
        @parent.single_resolvers.delete(res)
        @parent.single_resolvers.insert(index-1,res)
      end
    end

    # TO BE CALLED IN A SYNCHRONIZED BLOCK
    def decrement_resolver_priority(res)
      TheLog.debug("Decrementing resolver priority for #{res.server}\n")
      index = @parent.single_resolvers.index(res)
      if (index < @parent.single_resolvers.length)
        @parent.single_resolvers.delete(res)
        @parent.single_resolvers.insert(index+1,res)
      end
    end

    # TO BE CALLED IN A SYNCHRONIZED BLOCK
    def demote_resolver(res)
      TheLog.debug("Demoting resolver priority for #{res.server} to bottom\n")
      @parent.single_resolvers.delete(res)
      @parent.single_resolvers.push(res)
    end
    
    def handle_response(select_queue, query_id, response) #:nodoc: all
      # Handle a good response
      # Should also stick resolver more to the front of the list for future queries
      Dnsruby.log.debug{"Handling good response"}
      resolver, msg, client_query_id, retry_count = query_id
      increment_resolver_priority(resolver)
      #      @mutex.synchronize{
      query, client_queue, s_queue, outstanding = @query_list[client_query_id]
      if (s_queue != select_queue)
        Dnsruby.log.error{"Serious internal error : expected select queue #{s_queue}, got #{select_queue}"}
        raise RuntimeError.new("Serious internal error : expected select queue #{s_queue}, got #{select_queue}")
      end
      #        send_result_and_close(client_queue, client_query_id, select_queue, response, nil)
      stop_querying(client_query_id)
      # @TODO@ Does the client want notified at this point?
      #        client_queue.push([client_query_id, Resolver::EventType::RECEIVED, msg, nil])
      #      }
    end

    def handle_validation_response(select_queue, query_id, response) #:nodoc: all
      resolver, msg, client_query_id, retry_count = query_id
      #      @mutex.synchronize {
      query, client_queue, s_queue, outstanding = @query_list[client_query_id]
      if (s_queue != select_queue)
        Dnsruby.log.error{"Serious internal error : expected select queue #{s_queue}, got #{select_queue}"}
        raise RuntimeError.new("Serious internal error : expected select queue #{s_queue}, got #{select_queue}")
      end
      # @TODO@ Was there an error validating? Should we raise an exception for certain security levels?
      # This should be configurable by the client.
      #        send_result_and_close(client_queue, client_query_id, select_queue, response, nil)
      send_result(client_queue, client_query_id, select_queue, response, nil)
      #      }
    end
    
    def handle_validation_error(select_queue, query_id, error, response)
      resolver, msg, client_query_id, retry_count = query_id
      query, client_queue, s_queue, outstanding = @query_list[client_query_id]
      if (s_queue != select_queue)
        Dnsruby.log.error{"Serious internal error : expected select queue #{s_queue}, got #{select_queue}"}
        raise RuntimeError.new("Serious internal error : expected select queue #{s_queue}, got #{select_queue}")
      end
#      For some errors, we immediately send result. For others, should we retry?
#      Either :
#                handle_error_response(queue, event_id, error, response)
#                Or:
      send_result(client_queue, client_query_id, select_queue, response, error)
#                
#
    end
      end
end
require "Dnsruby/SingleResolver"