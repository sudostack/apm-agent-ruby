#
# frozen_string_literal: true

module ElasticAPM
  # @api private
  class Middleware
    include Logging

    def initialize(app)
      @app = app
    end

    # rubocop:disable Metrics/MethodLength
    def call(env)
      begin
        if running? && !path_ignored?(env)
          transaction = start_transaction(env)
        end

        resp = @app.call env
      rescue InternalError
        raise # Don't report ElasticAPM errors
      rescue ::Exception => e
        ElasticAPM.report(e, handled: false)
        raise
      ensure
        if resp && transaction
          status, headers, _body = resp
          transaction.add_response(status, headers: headers)
        end

        ElasticAPM.end_transaction http_result(status)
      end

      resp
    end
    # rubocop:enable Metrics/MethodLength

    private

    def http_result(status)
      status && "HTTP #{status.to_s[0]}xx"
    end

    def path_ignored?(env)
      config.ignore_url_patterns.any? do |r|
        env['PATH_INFO'].match r
      end
    end

    def start_transaction(env)
      if (transaction = ElasticAPM.current_transaction)
        transaction.name = transaction_name(env)
        transaction
      else
        ElasticAPM.start_transaction(
          transaction_name(env),
          'request',
          context: ElasticAPM.build_context(env),
          trace_context: trace_context(env)
        )
      end
    end

    def transaction_name(env)
      request_method = env['REQUEST_METHOD']
      [request_method, grape_route_name(env)].join(' ')
    end

    def grape_route_name(env)
      return origin(env) if origin(env)
      env['REQUEST_PATH']
    end

    def origin(env)
      env['api.endpoint'].respond_to?(:routes) &&
        env['api.endpoint'].routes.respond_to?(:first) &&
        env['api.endpoint'].routes.first.respond_to?(:pattern) &&
        env['api.endpoint'].routes.first.pattern.respond_to?(:origin)
    end

    def trace_context(env)
      return unless (header = env['HTTP_ELASTIC_APM_TRACEPARENT'])
      TraceContext.parse(header)
    rescue TraceContext::InvalidTraceparentHeader
      warn "Couldn't parse invalid traceparent header: #{header.inspect}"
      nil
    end

    def running?
      ElasticAPM.running?
    end

    def config
      @config ||= ElasticAPM.agent.config
    end
  end
end
