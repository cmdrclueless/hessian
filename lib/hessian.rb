require 'uri'
require 'net/http'
require 'net/https'

module Hessian
  VERSION = '1.0.2'

  class TypeWrapper
    attr_accessor :hessian_type, :object
    def initialize(hessian_type, object)
      @hessian_type, @object = hessian_type, object
    end

    # forward any unknown methods directly to the 
    # encapsulated object
    def method_missing(id, *args, &block)
      object.respond_to?(id) ? object.send(id, *args, &block) : super
    end
  end
  
  class Binary
    attr :data
    def initialize(data)
      @data = data.to_s
    end
  end

  class HessianException < RuntimeError
    attr_reader :code, :details
    def initialize(code, details=nil)
      @code = code
      @details = details
    end
  end

  class HessianClient
    attr_accessor :user, :password
    attr_reader :scheme, :host, :port, :path, :proxy
    def initialize(url, proxy = {})
      uri = URI.parse(url)
      @scheme, @host, @port, @path = uri.scheme, uri.host, uri.port, uri.path
      raise "Unsupported Hessian protocol: #@scheme" unless @scheme == 'http' || @scheme == 'https'
      @proxy = proxy
    end
    
    def method_missing(id, *args)
      return invoke(id.id2name, args)
    end

    private
    def invoke(method, args)
      call = HessianWriter.new.write_call method, args
      header = { 'Content-Type' => 'application/binary' }
      req = Net::HTTP::Post.new(@path, header)
      req.basic_auth @user, @password if @user
      conn = Net::HTTP.new(@host, @port, *@proxy.values_at(:host, :port, :user, :password))
      conn.use_ssl = true and conn.verify_mode = OpenSSL::SSL::VERIFY_NONE if @scheme == 'https'
      conn.start do |http|
        res = http.request(req, call)
        HessianParser.new.parse_response res.body
      end
    end

    class HessianWriter
      def write_call(method, args)
        @refs = {}
        out = [ 'c', '0', '1', 'm', method.length ].pack('ahhan') << method
        args.each { |arg| out << write_object(arg) }
        out << 'z'
      end

      private
      def write_object(val, hessian_type = nil)
        return 'N' if val.nil?
        case val
        when TypeWrapper
          write_object(val.object, val.hessian_type)
        when Struct
          write_object(val.members.inject({}) { |map, m| map[m] = val[m]; map })
        when Binary
          [ 'B', val.data.length ].pack('an') << val.data
        when String
          [ 'S', val.length ].pack('an') << val.unpack('C*').pack('U*')
        when Symbol
          [ 'S', val.to_s.length ].pack('an') << val.to_s.unpack('C*').pack('U*')
        when Integer
          # Max and min values for integers in Java.
          if val >= -0x80000000 && val <= 0x7fffffff
            [ 'I', val ].pack('aN')
          else
            "L%s" % to_long(val)
          end
        when Float
          [ 'D', val ].pack('aG')
        when Time
          "d%s" % to_long((val.to_f * 1000).to_i)
        when TrueClass
          'T'
        when FalseClass
          'F'
        when Array
          ref = write_ref val; return ref if ref
          t = hessian_type_string(hessian_type, val)
          str = 'Vt' << t << 'l' << [ val.length ].pack('N')
          val.each { |v| str << write_object(v) }
          str << 'z'
        when Hash
          ref = write_ref val; return ref if ref
          str = 'Mt' << hessian_type_string(hessian_type, val)
          val.each { |k, v| str << write_object(k); str << write_object(v) }
          str << 'z'
        else
          raise "Not implemented for #{val.class}"
        end
      end
      
      def hessian_type_string(hessian_type, object)
        if hessian_type.nil? && object.respond_to?(:hessian_type)
          hessian_type = object.hessian_type
        end        
        hessian_type ? [ hessian_type.length, hessian_type ].pack('na*') : "\000\000"
      end
      
      def to_long(val)
        str, pos = " " * 8, 0
        56.step(0, -8) { |o| str[pos] = val >> o & 0x00000000000000ff; pos += 1 }
        str
      end

      def write_ref(val)
        id = @refs[val.object_id]
        if id
          [ 'R', id ].pack('aN')
        else
          @refs[val.object_id] = @refs.length
          nil
        end
      end
    end

    class HessianParser
      def parse_response(res)
        raise "Invalid response, expected 'r', received '#{res[0,1]}'" unless res[0,1] == 'r'
        @chunks = []
        @refs = []
        @data = res[3..-1]
        parse_object
      end

      private
      def parse_object
        t = @data.slice!(0, 1)
        case t
        when 'f'
            raise_exception
        when 's', 'S', 'x', 'X'
          v = from_utf8(@data.slice!(0, 2).unpack('n')[0])
          @data.slice!(0, v[1])
          @chunks << v[0]
          if 'sx'.include? t
            parse_object
          else
            str = @chunks.join; @chunks.clear; str
          end
        when 'b', 'B'
          v = @data.slice!(0, @data.slice!(0, 2).unpack('n')[0])
          @chunks << v
          if t == 'b'
            parse_object
          else
            bytes = @chunks.join; @chunks.clear; Binary.new bytes
          end
        when 'I'
          @data.slice!(0, 4).unpack('N')[0]
        when 'L'
          parse_long
        when 'd'
           l = parse_long; Time.at(l / 1000, l % 1000 * 1000)
        when 'D'
           @data.slice!(0, 8).unpack('G')[0]
        when 'T'
          true
        when 'F'
          false
        when 'N'
          nil
        when 'R'
          @refs[@data.slice!(0, 4).unpack('N')[0]]
        when 'V'
          type = nil
          if @data[0,1] == 't'
            length = @data.slice!(0, 3).unpack('cn')[1]
            type   = @data.slice!(0, length).force_encoding('UTF-8')
          end
          # Skip the list length if specified.
          @data.slice!(0, 5) if @data[0,1] == 'l'
          @refs << (list = [])
          list << parse_object while @data[0,1] != 'z'
          @data.slice!(0, 1) # remove the final z

          type ? TypeWrapper.new(type, list) : list
        when 'M'
          type = nil
          if @data[0,1] == 't'
            length = @data.slice!(0, 3).unpack('cn')[1]
            type   = @data.slice!(0, length).force_encoding('UTF-8')
          end
          
          @refs << (map = {})
          map[parse_object()] = parse_object while @data[0,1] != 'z'
          @data.slice!(0, 1) # remove the final 'z'

          type ? TypeWrapper.new(type, map) : map
        else
          raise "Invalid type: '#{t}'"
        end
      end
      
      def from_utf8(len = '*')
        s = @data.unpack("U#{len}").pack('C*')
        [ s, s.unpack('C*').pack('U*').length ]
      end

      def parse_long
        val, o = 0, 56
        @data.slice!(0, 8).each_byte { |b| val += (b & 0xff) << o; o -= 8 }
        val
      end

      def raise_exception
        # Skip code description.
        key = parse_object
        raise RuntimeException, "Error in protocol stream, expected 'code'" unless key == 'code'
        code = parse_object
        
        key = parse_object
        raise RuntimeException, "Error in protocol stream, expected 'message'" unless key == 'message'
        msg = parse_object

        key = parse_object
        raise RuntimeException, "Error in protocol stream, expected 'detail'" unless key == 'detail'
        detail = parse_object

        raise HessianException.new(code,detail), msg
      end
    end
  end
end
