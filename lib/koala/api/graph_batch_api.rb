require 'koala/api'
require 'koala/api/batch_operation'

module Koala
  module Facebook
    # @private
    class GraphBatchAPI < API
      # inside a batch call we can do anything a regular Graph API can do
      include GraphAPIMethods

      attr_reader :original_api
      def initialize(access_token, api)
        super(access_token)
        @original_api = api
      end

      def batch_calls
        @batch_calls ||= []
      end

      def graph_call_in_batch(path, args = {}, verb = "get", options = {}, &post_processing)
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

      # redefine the graph_call method so we can use this API inside the batch block
      # just like any regular Graph API
      alias_method :graph_call_outside_batch, :graph_call
      alias_method :graph_call, :graph_call_in_batch

      # execute the queued batch calls
      def execute(http_options = {})
        return [] unless batch_calls.length > 0
        # Turn the call args collected into what facebook expects
        args = {}
        args["batch"] = MultiJson.dump(batch_calls.map { |batch_op|
          args.merge!(batch_op.files) if batch_op.files
          batch_op.to_batch_params(access_token)
        })

        batch_result = graph_call_outside_batch('/', args, 'post', http_options.merge(http_component: :response)) do |response|
          response_body = load_json(response.body)

          # Facebook sometimes reportedly returns an empty body at times
          # see https://github.com/arsduo/koala/issues/184
          raise bad_response("Facebook returned an empty body") if response_body.nil?
          raise bad_response("Facebook returned an invalid body") unless response_body.is_a?(Array)

          # map the results with post-processing included
          index = 0 # keep compat with ruby 1.8 - no with_index for map
          response_body.map do |call_result|
            # Get the options hash
            batch_op = batch_calls[index]
            index += 1

            raw_result = nil
            if call_result
              if (error = check_response(call_result['code'], call_result['body'].to_s))
                raw_result = error
              else
                # (see note in regular api method about JSON parsing)
                body = MultiJson.load("[#{call_result['body'].to_s}]")[0]

                # Get the HTTP component they want
                raw_result = case batch_op.http_options[:http_component]
                when :status
                  call_result["code"].to_i
                when :headers
                  format_headers(call_result['headers'])
                when :response
                  Koala::HTTPService::Response.new(
                    call_result["code"].to_i,
                    call_result["body"],
                    format_headers(call_result['headers'])
                  )
                else
                  body
                end
              end
            end

            # turn any results that are pageable into GraphCollections
            # and pass to post-processing callback if given
            result = GraphCollection.evaluate(raw_result, @original_api)
            if batch_op.post_processing
              batch_op.post_processing.call(result)
            else
              result
            end
          end
        end
      end

      private

      # facebook returns the headers as an array of k/v pairs, but we want a regular hash
      def format_headers(http_headers)
        http_headers.inject({}) do |headers, h|
          headers[h['name']] = h['value']
          headers
        end
      end

      # Prevents invalid json (e.g HTML code) from breaking the parser used
      # to process the API call
      def load_json(response_body)
        MultiJson.load("[#{response_body}]")[0]
      rescue MultiJson::ParseError => e
        raise BadFacebookResponse.new(200, '', "Facebook returned an invalid body #{e.class} #{e.message}")
      end

      def bad_response(message)
        BadFacebookResponse.new(200, '', message)
      end
    end
  end
end
