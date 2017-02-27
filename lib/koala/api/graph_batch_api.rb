require 'byebug'
require 'koala/api'
require 'koala/api/batch_operation'

module Koala
  module Facebook
    # @private
    class GraphBatchAPI
      # inside a batch call we can do anything a regular Graph API can do
      include GraphAPIMethods

      attr_reader :original_api
      def initialize(api)
        @original_api = api
      end

      def batch_calls
        @batch_calls ||= []
      end

      # Enqueue a call into the batch for later processing.
      # See API#graph_call
      def graph_call(path, args = {}, verb = 'get', options = {}, &post_processing)
        # normalize options for consistency
        options = Koala::Utils.symbolize_hash(options)

        # for batch APIs, we queue up the call details (incl. post-processing)
        batch_calls << BatchOperation.new(
          :url => path,
          :args => args,
          :method => verb,
          :access_token => options[:access_token] || access_token,
          :http_options => options,
          :post_processing => post_processing
        )
        nil # batch operations return nothing immediately
      end

      # execute the queued batch calls
      def execute(http_options = {})
        return [] if batch_calls.empty?

        # Turn the call args collected into what facebook expects
        args = { 'batch' => batch_args }
        batch_calls.each do |call|
          args.merge! call.files || {}
        end

        original_api.graph_call('/', args, 'post', http_options.merge(http_component: :response), &handle_response)
      end

      def handle_response
        lambda do |response|
          response_body = MultiJson.load("[#{response.body}]")[0]
          raise bad_response if response_body.nil?
          response_body.map(&generate_results)
        end
      end

      def generate_results
        index = 0
        lambda do |call_result|
          batch_op     = batch_calls[index]; index += 1
          post_process = batch_op.post_processing

          # turn any results that are pageable into GraphCollections
          result = GraphCollection.evaluate(
            result_from_response(call_result, batch_op),
            original_api
          )

          # and pass to post-processing callback if given
          if post_process
            post_process.call(result)
          else
            result
          end
        end
      end

      def bad_response
        # Facebook sometimes reportedly returns an empty body at times
        BadFacebookResponse.new(200, '', 'Facebook returned an empty body')
      end

      def result_from_response(response, options)
        return nil if response.nil?

        headers   = coerced_headers_from_response(response)
        error     = error_from_response(response, headers)
        component = options.http_options[:http_component]

        error || result_from_component({
          :component => component,
          :response  => response,
          :headers   => headers
        })
      end

      def coerced_headers_from_response(response)
        headers = response.fetch('headers', [])

        headers.each_with_object({}) do |h, memo|
          memo.merge! h.fetch('name') => h.fetch('value')
        end
      end

      def error_from_response(response, headers)
        code = response['code']
        body = response['body'].to_s

        GraphErrorChecker.new(code, body, headers).error_if_appropriate
      end

      def batch_args
        calls = batch_calls.map do |batch_op|
          batch_op.to_batch_params(access_token, app_secret)
        end

        JSON.dump calls
      end

      def json_body(response)
        # quirks_mode is needed because Facebook sometimes returns a raw true or false value --
        # in Ruby 2.4 we can drop that.
        JSON.parse(response.fetch('body'), quirks_mode: true)
      end

      def result_from_component(options)
        component = options.fetch(:component)
        response  = options.fetch(:response)
        headers   = options.fetch(:headers)

        byebug
        # Get the HTTP component they want
        case component
        when :status  then response['code'].to_i
        # facebook returns the headers as an array of k/v pairs, but we want a regular hash
        when :headers then headers
        when :response
          Koala::HTTPService::Response.new(
            response['code'].to_i,
            json_body(response),
            headers
          )
        # (see note in regular api method about JSON parsing)
        else json_body(response)
        end
      end

      def access_token
        original_api.access_token
      end

      def app_secret
        original_api.app_secret
      end
    end
  end
end
