# frozen_string_literal: true

class ApplicationRestClient
  module Errors
    class RestError < StandardError
      attr_accessor :method, :path, :response, :trace

      # This constructor used to take in (method, path, response, trace), *_args is there to guard against old usage
      # Initializing with those parameters is now accomplished via .with_details class method
      # This was changed to accept msg as a parameter mainly to workaround a mini-racer issue:
      # https://github.com/rubyjs/mini_racer/issues/165
      def initialize(msg, *_args)
        super(msg)
      end

      def self.msg_from_args(method, path, response, trace)
        <<~MESSAGE
          #{name.demodulize.underscore.humanize} (HTTP #{response.code}): #{method.to_s.upcase} #{path}

          #{trace}
        MESSAGE
      end

      def self.with_details(method, path, response, trace)
        new(msg_from_args(method, path, response, trace)).tap { |e| e.save_details(method, path, response, trace) }
      end

      def save_details(method, path, response, trace)
        self.method = method
        self.path = path
        self.response = response
        self.trace = trace
      end
    end

    class BadRequest < RestError; end

    class Unauthorized < RestError; end

    class PaymentRequired < RestError; end

    class Forbidden < RestError; end

    class NotFound < RestError; end

    class RequestTimeout < RestError; end

    class TooManyRequests < RestError; end

    class InternalServerError < RestError; end

    class Conflict < RestError; end

    class RestErrorWithDetails < RestError
      RESPONSE_DESCRIPTION = 'override with relevent description'

      def self.with_details(method, path, trace)
        args = [method, path, Hashie::Mash.new(code: -1, description: RESPONSE_DESCRIPTION), trace]
        new(msg_from_args(*args)).tap { |e| e.save_details(*args) }
      end
    end

    class SslError < RestErrorWithDetails
      RESPONSE_DESCRIPTION = 'This is a fake response for SSL failure'
    end

    class TimeoutError < RestErrorWithDetails
      RESPONSE_DESCRIPTION = 'This is a fake response for Request timeout'
    end

    class CantConnectError < RestErrorWithDetails
      RESPONSE_DESCRIPTION = 'This is a fake response for being unable to connect'
    end

    class RequestError < RestErrorWithDetails
      RESPONSE_DESCRIPTION = 'This is a fake response for a network/request error'
    end
  end

  attr_accessor :base_url, :debug

  def initialize(base_url:, debug: false)
    @base_url = base_url
    @debug = debug
  end

  def self.generate_query(query, query_param_method: nil)
    reutrn if query.blank?

    case query_param_method
    when :rails_to_query
      query.to_query
    when :plain
      query.map { |k, v| "#{k}=#{v}" }.join('&')
    else
      URI.encode_www_form(query)
    end
  end

  def self.generate_xml(body)
    body if body.is_a?(String)

    # If xml needed in the future uncomment line below
    # "<?xml version=\"1.0\" encoding=\"UTF-8\"?>#{Gyoku.xml(body, key_converter: :none)}"
  end

  def url_for(path, query, query_param_method: :encode_www_form)
    u = URI(base_url)
    u.query = self.class.generate_query(query, query_param_method:) if query.present?

    u.path = if u.path&.length&.positive?
               if u.path[-1] == '/' || path[0] == '/'
                 u.path + path
               else
                 "#{u.path}/#{path}"
               end
             else
               path
             end

    u.to_s
  end

  def request( # rubocop:disable Metrics/ParameterLists
    method,
    path,
    body: nil,
    query: nil,
    headers: nil,
    basic_auth: nil,
    debug: false,
    skip_capture: false,
    body_encoding: :json,
    proxy: nil, # proxy keys supported are addr, port, user, pass
    query_param_method: :encode_www_form,
    timeout: nil,
    follow_redirects: true
  ) # follow_redirects is true by default in httparty
    options = {}.tap do |o|
      o[:headers] = {}.tap do |h|
        h[:Accept] = 'application/json'

        case body_encoding
        when :json
          h['Content-Type'] = 'application/json'
        when :form
          h['Content-Type'] = 'application/x-www-form-urlencoded'
        when :xml
          h['Content-Type'] = 'application/xml'
        end
      end
    end

    (headers || {}).each_pair do |k, v|
      options[:headers][k.to_sym] = v
    end

    capture_stream = nil
    debug_stream = nil

    # Value of basic_auth should be {username: '', password: ''}
    options[:basic_auth] = basic_auth if basic_auth
    options[:timeout] = timeout if timeout
    options[:follow_redirects] = follow_redirects

    if @debug || debug
      options[:debug_output] = Rails.logger # if debug
    elsif !skip_capture
      capture_stream = StringIO.new
      options[:debug_output] = capture_stream
    end

    if body
      options[:body] = case body_encoding
                       when :json
                         body.to_json
                       when :form
                         URI.encode_www_form(body)
                       when :multipart_form
                         body
                       when :xml
                         self.class.generate_xml(body)
                       else
                         body.to_s
                       end
    end

    proxy&.slice(:addr, :port, :user, :pass)&.each { |k, v| options[:"http_proxy#{k}"] = v }

    final_url = url_for(path, query, query_param_method:)
    begin
      raise_error_class = nil
      response = HTTParty.send(method, final_url, options)
    rescue OpenSSL::SSL::SSLError
      raise_error_class = Errors::SslError
    rescue Timeout::Error
      raise_error_class = Errors::TimeoutError
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ECONNRESET
      raise_error_class = Errors::CantConnectError
    rescue HTTParty::ResponseError
      # Handles all Net:: errrs , redirection errors, duplicate location header
      # https://github.com/jnunemaker/httparty/blob/master/lib/httparty/exceptions.rb#L15
      raise_error_class = Errors::RequestError
    end

    if capture_stream
      capture_stream.rewind
      debug_stream = capture_stream.read
      capture_stream.close
    end

    if raise_error_class
      response = nil
      raise raise_error_class.with_details(method, final_url, debug_stream)
    end

    validate_response(
      response,
      method:,
      path: final_url,
      debug_stream:
    )
  end

  private

  def validate_response(response, method:, path:, debug_stream:, expected_statuses: nil)
    if (!expected_statuses && (1..399).exclude?(response.code)) || expected_statuses&.exclude?(response.code)
      args = [method, path, response, debug_stream]
      case response.code
      when 400
        raise Errors::BadRequest.with_details(*args)
      when 401
        raise Errors::Unauthorized.with_details(*args)
      when 402
        raise Errors::PaymentRequired.with_details(*args)
      when 403
        raise Errors::Forbidden.with_details(*args)
      when 404
        raise Errors::NotFound.with_details(*args)
      when 408
        raise Errors::RequestTimeout.with_details(*args)
      when 409
        raise Errors::Conflict.with_details(*args)
      when 429
        raise Errors::TooManyRequests.with_details(*args)
      when 500..599
        raise Errors::InternalServerError.with_details(*args)
      else
        raise Errors::RestError.with_details(*args)
      end
    end

    # No error, return response
    response
  end
end
