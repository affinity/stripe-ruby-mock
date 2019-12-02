module StripeMock
  module RequestHandlers
    module SubscriptionSchedules

      def SubscriptionSchedules.included(klass)
        klass.add_handler 'post /v1/subscription_schedules', :create_subscription_schedule
        klass.add_handler 'get /v1/subscription_schedules/(.*)', :retrieve_subscription_schedule
        klass.add_handler 'post /v1/subscription_schedules/(.*)', :update_subscription_schedule

        # NOT USED
        # POST /v1/subscription_schedules/:id/cancel
        # POST /v1/subscription_schedules/:id/release
        #  GET /v1/subscription_schedules
      end

      def create_subscription_schedule(route, method_url, params, headers)
        if headers && headers[:idempotency_key]
          if subscription_schedules.any?
            original_subscription = subscription_schedules.values.find { |c| c[:idempotency_key] == headers[:idempotency_key]}
            puts original_subscription
            return subscription_schedules[original_subscription[:id]] if original_subscription
          end
        end
        route =~ method_url

        subscription_plans = get_subscription_plans_from_params(params)

        customer = params[:customer]
        customer_id = customer.is_a?(Stripe::Customer) ? customer[:id] : customer.to_s
        customer = assert_existence :customer, customer_id, customers[customer_id]

        if subscription_plans && customer
          subscription_plans.each do |plan|
            unless customer[:currency].to_s == plan[:currency].to_s
              raise Stripe::InvalidRequestError.new("Customer's currency of #{customer[:currency]} does not match plan's currency of #{plan[:currency]}", 'currency', http_status: 400)
            end
          end
        end

        if params[:source]
          new_card = get_card_by_token(params.delete(:source))
          add_card_to_object(:customer, new_card, customer)
          customer[:default_source] = new_card[:id]
        end

        allowed_params = %w(customer application_fee_percent coupon items metadata plan quantity source tax_percent trial_end trial_period_days current_period_start created prorate billing_cycle_anchor billing days_until_due idempotency_key enable_incomplete_payments cancel_at_period_end default_tax_rates collection_method)
        unknown_params = params.keys - allowed_params.map(&:to_sym)
        if unknown_params.length > 0
          raise Stripe::InvalidRequestError.new("Received unknown parameter: #{unknown_params.join}", unknown_params.first.to_s, http_status: 400)
        end

        subscription = Data.mock_subscription({ id: (params[:id] || new_id('su')) })
        subscription = resolve_subscription_changes(subscription, subscription_plans, customer, params)
        if headers[:idempotency_key]
          subscription[:idempotency_key] = headers[:idempotency_key]
        end

        # Ensure customer has card to charge if plan has no trial and is not free
        # Note: needs updating for subscriptions with multiple plans
        verify_card_present(customer, subscription_plans.first, subscription, params)

        if params[:coupon]
          coupon_id = params[:coupon]

          # assert_existence returns 404 error code but Stripe returns 400
          # coupon = assert_existence :coupon, coupon_id, coupons[coupon_id]

          coupon = coupons[coupon_id]

          if coupon
            add_coupon_to_object(subscription, coupon)
          else
            raise Stripe::InvalidRequestError.new("No such coupon: #{coupon_id}", 'coupon', http_status: 400)
          end
        end

        if params[:cancel_at_period_end]
          subscription[:cancel_at_period_end] = true
          subscription[:canceled_at] = Time.now.utc.to_i
        end

        subscriptions[subscription[:id]] = subscription
        add_subscription_to_customer(customer, subscription)

        subscriptions[subscription[:id]]
      end

      def retrieve_subscription_schedule(route, method_url, params, headers)
        route =~ method_url

        assert_existence :subscription, $1, subscriptions[$1]
      end

      def update_subscription_schedule(route, method_url, params, headers)
        route =~ method_url

        subscription_id = $2 ? $2 : $1
        subscription = assert_existence :subscription, subscription_id, subscriptions[subscription_id]
        verify_active_status(subscription)

        customer_id = subscription[:customer]
        customer = assert_existence :customer, customer_id, customers[customer_id]

        if params[:source]
          new_card = get_card_by_token(params.delete(:source))
          add_card_to_object(:customer, new_card, customer)
          customer[:default_source] = new_card[:id]
        end

        subscription_plans = get_subscription_plans_from_params(params)

        # subscription plans are not being updated but load them for the response
        if subscription_plans.empty?
          subscription_plans = subscription[:items][:data].map { |item| item[:plan] }
        end

        if params[:coupon]
          coupon_id = params[:coupon]

          # assert_existence returns 404 error code but Stripe returns 400
          # coupon = assert_existence :coupon, coupon_id, coupons[coupon_id]

          coupon = coupons[coupon_id]
          if coupon
            add_coupon_to_object(subscription, coupon)
          elsif coupon_id == ""
            subscription[:discount] = nil
          else
            raise Stripe::InvalidRequestError.new("No such coupon: #{coupon_id}", 'coupon', http_status: 400)
          end
        end

        if params[:cancel_at_period_end]
          subscription[:cancel_at_period_end] = true
          subscription[:canceled_at] = Time.now.utc.to_i
        elsif params.has_key?(:cancel_at_period_end)
          subscription[:cancel_at_period_end] = false
          subscription[:canceled_at] = nil
        end

        params[:current_period_start] = subscription[:current_period_start]
        params[:trial_end] = params[:trial_end] || subscription[:trial_end]

        plan_amount_was = subscription.dig(:plan, :amount)

        subscription = resolve_subscription_changes(subscription, subscription_plans, customer, params)

        verify_card_present(customer, subscription_plans.first, subscription, params) if plan_amount_was == 0 && subscription.dig(:plan, :amount) && subscription.dig(:plan, :amount) > 0

        # delete the old subscription, replace with the new subscription
        customer[:subscriptions][:data].reject! { |sub| sub[:id] == subscription[:id] }
        customer[:subscriptions][:data] << subscription

        subscription
      end

      private

      def get_subscription_plans_from_params(params)
        plan_ids = if params[:plan]
                     [params[:plan].to_s]
                   elsif params[:items]
                     items = params[:items]
                     items = items.values if items.respond_to?(:values)
                     items.map { |item| item[:plan].to_s if item[:plan] }
                   else
                     []
                   end
        plan_ids.each do |plan_id|
          assert_existence :plan, plan_id, plans[plan_id]
        end
        plan_ids.map { |plan_id| plans[plan_id] }
      end
    end
  end
end
