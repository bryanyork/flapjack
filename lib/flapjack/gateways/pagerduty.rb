#!/usr/bin/env ruby

require 'oj'

require 'net/http'
require 'uri'
require 'uri/https'

require 'flapjack'

require 'flapjack/data/alert'
require 'flapjack/data/entity_check'
require 'flapjack/data/message'

require 'flapjack/exceptions'

module Flapjack

  module Gateways

    class Pagerduty

      class Notifier

        def initialize(opts = {})
          @lock = opts[:lock]
          @config = opts[:config]
          @logger = opts[:logger]

          @notifications_queue = @config['queue'] || 'pagerduty_notifications'

          @logger.debug("New Pagerduty::Notifier pikelet with the following options: #{@config.inspect}")
        end

        def redis_connections_required
          1
        end

        def start
          @logger.info("starting")
          until test_pagerduty_connection
            @logger.error("Can't connect to the pagerduty API, retrying after 10 seconds")
            Kernel.sleep(10)
          end

          loop do
            @lock.synchronize do
              Flapjack::Data::Message.foreach_on_queue(@notifications_queue) {|message|
                handle_message(message)
              }
            end

            Flapjack::Data::Message.wait_for_queue(@notifications_queue)
          end
        end

        def stop_type
          :exception
        end

        private

        def handle_message(message)
          @logger.debug("pagerduty notification event received: " + message.inspect)

          alert = Flapjack::Data::Alert.new(message, :logger => @logger)
          @logger.debug("processing pagerduty notification service_key: #{alert.address}, entity: #{alert.entity}, " +
                        "check: '#{alert.check}', state: #{alert.state}, summary: #{alert.summary}")

          mydir = File.dirname(__FILE__)
          message_template_path = mydir + "/pagerduty/alert.text.erb"
          message_template = ERB.new(File.read(message_template_path), nil, '-')

          @alert = alert
          bnd = binding

          msg = nil
          begin
            msg = message_template.result(bnd).chomp
          rescue => e
            @logger.error "Error while executing the ERB for a pagerduty message, " +
              "ERB being executed: #{message_template_path}"
            raise
          end

          pagerduty_type = case alert.type
          when 'acknowledgement'
            'acknowledge'
          when 'problem'
            'trigger'
          when 'recovery'
            'resolve'
          when 'test'
            'trigger'
          end

          send_pagerduty_event(:service_key  => alert.address,
                               :incident_key => alert.event_id,
                               :event_type   => pagerduty_type,
                               :description  => msg)
          alert.record_send_success!
        rescue => e
          @logger.error "Error generating or dispatching pagerduty message: #{e.class}: #{e.message}\n" +
            e.backtrace.join("\n")
          @logger.debug "Message that could not be processed: \n" + message.inspect
        end

        def test_pagerduty_connection
          code, results = send_pagerduty_event(:service_key => '11111111111111111111111111111111',
                                               :incident_key => 'Flapjack is running a NOOP',
                                               :event_type => 'nop',
                                               :description => 'I love APIs with noops.')
          return true if '200'.eql?(code) && results['status'] =~ /success/i
          @logger.error "Error: test_pagerduty_connection: API returned #{code.to_s} #{results.inspect}"
          false
        end

        # TODO trap Oj JSON errors
        def send_pagerduty_event(opts = {})
          event = { 'service_key'  => opts[:service_key],
                    'incident_key' => opts[:incident_key],
                    'event_type'   => opts[:event_type],
                    'description'  => opts[:description] }

          uri = URI::HTTPS.build(:host => 'events.pagerduty.com',
                                 :port => 443,
                                 :path => '/generic/2010-04-15/create_event.json')
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          request = Net::HTTP::Post.new(uri.request_uri)
          request.body = Oj.dump(event)
          http_response = http.request(request)

          response = Oj.load(http_response.body)
          status   = http_response.code
          @logger.debug "send_pagerduty_event got a return code of #{status} - #{response.inspect}"
          unless status.to_i == 200
            raise "Error sending event to pagerduty: status: #{status.to_s} - #{response.inspect}" +
                  " posted data: #{options[:body]}"
          end
          [status, response]
        end

      end

      class AckFinder

        SEM_PAGERDUTY_ACKS_RUNNING = 'sem_pagerduty_acks_running'

        def initialize(opts = {})
          @lock = opts[:lock]
          @config = opts[:config]
          @logger = opts[:logger]

          @logger.debug("New Pagerduty::AckFinder pikelet with the following options: #{@config.inspect}")

          # TODO: only clear this if there isn't another pagerduty gateway instance running
          # or better, include an instance ID in the semaphore key name
          Flapjack.redis.del(SEM_PAGERDUTY_ACKS_RUNNING)
        end

        def start
          loop do
            @lock.synchronize do
              # ensure we're the only instance of the pagerduty acknowledgement check running (with a naive
              # timeout of five minutes to guard against stale locks caused by crashing code) either in this
              # process or in other processes
              if Flapjack.redis.setnx(SEM_PAGERDUTY_ACKS_RUNNING, 'true') == 0
                @logger.debug("skipping looking for acks in pagerduty as this is already happening")
              else
                Flapjack.redis.expire(SEM_PAGERDUTY_ACKS_RUNNING, 300)
                find_pagerduty_acknowledgements
                Flapjack.redis.del(SEM_PAGERDUTY_ACKS_RUNNING)
              end
            end

            Kernel.sleep 10
          end
        end

        def stop_type
          :exception
        end

        def find_pagerduty_acknowledgements
          @logger.debug("looking for acks in pagerduty for unack'd problems")

          unacked_failing_checks = Flapjack::Data::EntityCheck.find_all_failing_unacknowledged

          @logger.debug "found unacknowledged failing checks as follows: " + unacked_failing_checks.join(', ')

          unacked_failing_checks.each do |event_id|

            entity_check = Flapjack::Data::EntityCheck.for_event_id(event_id)

            # If more than one contact for this entity_check has pagerduty
            # credentials then there'll be one hash in the array for each set of
            # credentials.
            ec_credentials = entity_check.contacts.inject([]) {|ret, contact|
              cred = contact.pagerduty_credentials
              ret << cred if cred
              ret
            }

            entity_name = entity_check.entity_name
            check = entity_check.check

            if ec_credentials.empty?
              @logger.debug("No pagerduty credentials found for #{entity_name}:#{check}, skipping")
              next
            end

            # FIXME: try each set of credentials until one works (may have stale contacts turning up)
            options = ec_credentials.first.merge('check' => "#{entity_name}:#{check}")

            acknowledged = pagerduty_acknowledged?(options)
            if acknowledged.nil?
              @logger.debug "#{entity_name}:#{check} is not acknowledged in pagerduty, skipping"
              next
            end

            pg_acknowledged_by = acknowledged[:pg_acknowledged_by]
            @logger.info "#{entity_name}:#{check} is acknowledged in pagerduty, creating flapjack acknowledgement... "
            who_text = ""
            if !pg_acknowledged_by.nil? && !pg_acknowledged_by['name'].nil?
              who_text = " by #{pg_acknowledged_by['name']}"
            end

            # FIXME: decide where the default acknowledgement period should reside and use it
            # everywhere ... a case for moving configuration into redis (from config file) perhaps?
            four_hours = 4 * 60 * 60
            Flapjack::Data::Event.create_acknowledgement(
              @config['processor_queue'] || 'events',
              entity_name, check,
              :summary  => "Acknowledged on PagerDuty" + who_text,
              :duration => four_hours)
          end

        end

        def pagerduty_acknowledged?(opts = {})
          subdomain   = opts['subdomain']
          username    = opts['username']
          password    = opts['password']
          check       = opts['check']

          t = Time.now.utc

          query = {'fields'       => 'incident_number,status,last_status_change_by',
                   'since'        => (t - (60*60*24*7)).iso8601, # the last week
                   'until'        => (t + (60*60*24)).iso8601,   # 1 day in the future
                   'incident_key' => check,
                   'status'       => 'acknowledged'}

          uri = URI::HTTPS.build(:host => "#{subdomain}.pagerduty.com",
                                 :path => '/api/v1/incidents',
                                 :port => 443,
                                 :query => URI.encode_www_form(query))
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          request = Net::HTTP::Get.new(uri.request_uri)
          request.basic_auth(username, password)

          @logger.debug("pagerduty_acknowledged?: request to #{uri.request_uri}")
          @logger.debug("pagerduty_acknowledged?: query: #{query.inspect}")
          @logger.debug("pagerduty_acknowledged?: auth: #{username}, #{password}")

          http_response = http.request(request)

          begin
            response = Oj.load(http_response.body)
          rescue Oj::Error
            @logger.error("failed to parse json from a post to #{url} ... response headers and body follows...")
            return nil
          end
          @logger.debug(http_response.inspect)
          status   = http_response.code

          @logger.debug("pagerduty_acknowledged?: decoded response as: #{response.inspect}")
          if response.nil?
            @logger.error('no valid response received from pagerduty!')
            return nil
          end

          if response['incidents'].nil?
            @logger.error('no incidents found in response')
            return nil
          end

          return nil if response['incidents'].empty?

          {:pg_acknowledged_by => response['incidents'].first['last_status_change_by']}
        end

      end

    end

  end

end

