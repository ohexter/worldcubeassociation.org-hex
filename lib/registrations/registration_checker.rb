# frozen_string_literal: true

module Registrations
  class RegistrationChecker
    def self.create_registration_allowed!(registration_request, target_user, competition)
      guests = registration_request['guests']
      comment = registration_request.dig('competing', 'comment')

      r = Registration.new(guests: guests.to_i, competition: competition, comments: comment, user: target_user)

      validate_create_events!(registration_request, competition)
      validate_qualifications!(registration_request, competition, target_user)
      # Migrated to ActiveRecord-style validations
      validate_guests!(r)
      validate_comment!(r)
    end

    def self.update_registration_allowed!(update_request, competition, current_user)
      registration = Registration.find_by(competition_id: competition.id, user_id: update_request['user_id'])
      raise WcaExceptions::RegistrationError.new(:not_found, Registrations::ErrorCodes::REGISTRATION_NOT_FOUND) if registration.blank?

      target_user = User.find(update_request['user_id'])
      waiting_list_position = update_request.dig('competing', 'waiting_list_position')
      comment = update_request.dig('competing', 'comment')
      organizer_comment = update_request.dig('competing', 'organizer_comment')
      guests = update_request['guests']
      new_status = update_request.dig('competing', 'status')
      events = update_request.dig('competing', 'event_ids')

      registration.guests = guests.to_i if update_request.key?('guests')
      competing_payload = update_request['competing']
      registration.comments = comment if competing_payload&.key?('comment')
      registration.administrative_notes = organizer_comment if competing_payload&.key?('organizer_comment')

      user_can_modify_registration!(competition, current_user, target_user, registration, new_status)
      # Migrated to ActiveRecord-style validations
      validate_guests!(registration)
      validate_comment!(registration)
      validate_organizer_comment!(registration)
      # Old-style validations within this class
      validate_organizer_fields!(update_request, current_user, competition)
      validate_waiting_list_position!(waiting_list_position, competition, registration) unless waiting_list_position.nil?
      validate_update_status!(new_status, competition, current_user, target_user, registration, events) unless new_status.nil?
      validate_update_events!(events, competition) unless events.nil?
      validate_qualifications!(update_request, competition, target_user) unless events.nil?
    end

    def self.bulk_update_allowed!(bulk_update_request, current_user)
      update_requests = bulk_update_request['requests']
      raise WcaExceptions::BulkUpdateError.new(:bad_request, [Registrations::ErrorCodes::INVALID_REQUEST_DATA]) if
        update_requests.blank?

      competition = Competition.find(bulk_update_request['competition_id'])

      raise WcaExceptions::RegistrationError.new(:forbidden, Registrations::ErrorCodes::COMPETITOR_LIMIT_REACHED) if
        will_exceed_competitor_limit?(update_requests, competition)

      raise WcaExceptions::BulkUpdateError.new(:unauthorized, [Registrations::ErrorCodes::USER_INSUFFICIENT_PERMISSIONS]) unless
        current_user.can_manage_competition?(competition)

      errors = {}
      update_requests.each do |update_request|
        update_registration_allowed!(update_request, competition, current_user)
      rescue WcaExceptions::RegistrationError => e
        errors[update_request['user_id']] = e.error
      end

      raise WcaExceptions::BulkUpdateError.new(:unprocessable_entity, errors) unless errors.empty?
    end

    class << self
      def will_exceed_competitor_limit?(update_requests, competition)
        registrations_to_be_accepted = update_requests.count { |r| r.dig('competing', 'status') == Registrations::Helper::STATUS_ACCEPTED }
        total_accepted_registrations_after_update = competition.registrations.accepted_count + registrations_to_be_accepted

        competition.competitor_limit_enabled &&
          registrations_to_be_accepted > 0 &&
          total_accepted_registrations_after_update > competition.competitor_limit
      end

      def user_can_modify_registration!(competition, current_user, target_user, registration, new_status)
        raise WcaExceptions::RegistrationError.new(:unauthorized, Registrations::ErrorCodes::USER_INSUFFICIENT_PERMISSIONS) unless
          can_administer_or_current_user?(competition, current_user, target_user)
        raise WcaExceptions::RegistrationError.new(:forbidden, Registrations::ErrorCodes::USER_EDITS_NOT_ALLOWED) unless
          competition.registration_edits_currently_permitted? || current_user.can_manage_competition?(competition) || user_uncancelling_registration?(registration, new_status)
        raise WcaExceptions::RegistrationError.new(:unauthorized, Registrations::ErrorCodes::REGISTRATION_IS_REJECTED) if
          user_is_rejected?(current_user, target_user, registration) && !organizer_modifying_own_registration?(competition, current_user, target_user)
        raise WcaExceptions::RegistrationError.new(:forbidden, Registrations::ErrorCodes::ALREADY_REGISTERED_IN_SERIES) if
          existing_registration_in_series?(competition, target_user) && !current_user.can_manage_competition?(competition)
      end

      def user_uncancelling_registration?(registration, new_status)
        registration.competing_status_cancelled? && new_status == Registrations::Helper::STATUS_PENDING
      end

      def user_is_rejected?(current_user, target_user, registration)
        current_user.id == target_user.id && registration.rejected?
      end

      def organizer_modifying_own_registration?(competition, current_user, target_user)
        (current_user.id == target_user.id) && current_user.can_manage_competition?(competition)
      end

      def can_administer_or_current_user?(competition, current_user, target_user)
        # Only an organizer or the user themselves can create a registration for the user
        # One case where organizers need to create registrations for users is if a 3rd-party registration system is being used, and registration data is being
        # passed to the Registration Service from it
        (current_user.id == target_user.id) || current_user.can_manage_competition?(competition)
      end

      def validate_create_events!(request, competition)
        event_ids = request['competing']['event_ids']
        # Event submitted must be held at the competition
        raise WcaExceptions::RegistrationError.new(:unprocessable_entity, Registrations::ErrorCodes::INVALID_EVENT_SELECTION) unless
          event_ids.present? && competition.events_held?(event_ids)

        event_limit = competition.events_per_registration_limit
        raise WcaExceptions::RegistrationError.new(:forbidden, Registrations::ErrorCodes::INVALID_EVENT_SELECTION) if
          competition.event_restrictions? && event_limit.present? && event_ids.count > event_limit
      end

      def validate_qualifications!(request, competition, target_user)
        return unless competition.enforces_qualifications?

        event_ids = request.dig('competing', 'event_ids')

        unqualified_events = event_ids.filter do |event|
          qualification = competition.qualification_wcif[event]
          qualification.present? && !competitor_qualifies_for_event?(event, qualification, target_user)
        end

        raise WcaExceptions::RegistrationError.new(:unprocessable_entity, Registrations::ErrorCodes::QUALIFICATION_NOT_MET, unqualified_events) unless unqualified_events.empty?
      end

      def process_validation_error!(registration, field)
        return if registration.valid?

        error_details = registration.errors.details[field].first

        return if error_details.blank?

        frontend_code = error_details[:frontend_code] || Registrations::ErrorCodes::INVALID_REQUEST_DATA
        raise WcaExceptions::RegistrationError.new(:unprocessable_entity, frontend_code, error_details)
      end

      def validate_guests!(registration)
        process_validation_error!(registration, :guests)
      end

      def validate_comment!(registration)
        process_validation_error!(registration, :comments)
      end

      def validate_organizer_fields!(request, current_user, competition)
        organizer_fields = ['organizer_comment', 'waiting_list_position']

        raise WcaExceptions::RegistrationError.new(:unauthorized, Registrations::ErrorCodes::USER_INSUFFICIENT_PERMISSIONS) if contains_organizer_fields?(request, organizer_fields) && !current_user.can_manage_competition?(competition)
      end

      def validate_organizer_comment!(registration)
        process_validation_error!(registration, :administrative_notes)
      end

      def validate_waiting_list_position!(waiting_list_position, competition, registration)
        # User must be on the wating list
        raise WcaExceptions::RegistrationError.new(:unprocessable_entity, Registrations::ErrorCodes::INVALID_REQUEST_DATA) unless
         registration.competing_status == Registrations::Helper::STATUS_WAITING_LIST

        # Floats are not allowed
        raise WcaExceptions::RegistrationError.new(:unprocessable_entity, Registrations::ErrorCodes::INVALID_WAITING_LIST_POSITION) if waiting_list_position.is_a? Float

        # We convert strings to integers and then check if they are an integer
        converted_position = Integer(waiting_list_position, exception: false)
        raise WcaExceptions::RegistrationError.new(:unprocessable_entity, Registrations::ErrorCodes::INVALID_WAITING_LIST_POSITION) unless converted_position.is_a? Integer

        waiting_list = competition.waiting_list.entries
        raise WcaExceptions::RegistrationError.new(:forbidden, Registrations::ErrorCodes::INVALID_WAITING_LIST_POSITION) if waiting_list.empty? && converted_position != 1
        raise WcaExceptions::RegistrationError.new(:forbidden, Registrations::ErrorCodes::INVALID_WAITING_LIST_POSITION) if converted_position > waiting_list.length
        raise WcaExceptions::RegistrationError.new(:forbidden, Registrations::ErrorCodes::INVALID_WAITING_LIST_POSITION) if converted_position < 1
      end

      def contains_organizer_fields?(request, organizer_fields)
        request['competing']&.keys&.any? { |key| organizer_fields.include?(key) }
      end

      # rubocop:disable Metrics/ParameterLists
      def validate_update_status!(new_status, competition, current_user, target_user, registration, events)
        raise WcaExceptions::RegistrationError.new(:unprocessable_entity, Registrations::ErrorCodes::INVALID_REQUEST_DATA) unless
          Registration.competing_statuses.include?(new_status)
        raise WcaExceptions::RegistrationError.new(:forbidden, Registrations::ErrorCodes::ALREADY_REGISTERED_IN_SERIES) if
          new_status == Registrations::Helper::STATUS_ACCEPTED && existing_registration_in_series?(competition, target_user)

        if new_status == Registrations::Helper::STATUS_ACCEPTED && competition.competitor_limit_enabled?
          raise WcaExceptions::RegistrationError.new(:forbidden, Registrations::ErrorCodes::COMPETITOR_LIMIT_REACHED) if
            competition.registrations.competing_status_accepted.count >= competition.competitor_limit

          if competition.enforce_newcomer_month_reservations? && !target_user.newcomer_month_eligible?
            available_spots = competition.competitor_limit - competition.registrations.competing_status_accepted.count

            # There are a limited number of "reserved" spots for newcomer_month_eligible competitions
            # We know that there are _some_ available_spots in the comp available, because we passed the competitor_limit check above
            # However, we still don't know how many of the reserved spots have been taken up by newcomers, versus how many "general" spots are left
            # For a non-newcomer to be accepted, there need to be more spots available than spots still reserved for newcomers
            raise WcaExceptions::RegistrationError.new(:forbidden, Registrations::ErrorCodes::NO_UNRESERVED_SPOTS_REMAINING) unless
              available_spots > competition.newcomer_month_reserved_spots_remaining
          end
        end

        # Otherwise, organizers can make any status change they want to
        return if current_user.can_manage_competition?(competition)

        # A user (ie not an organizer) is only allowed to:
        # 1. Reactivate their registration if they previously cancelled it (ie, change status from 'cancelled' to 'pending')
        # 2. Cancel their registration, assuming they are allowed to cancel

        # User reactivating registration
        if new_status == Registrations::Helper::STATUS_PENDING
          raise WcaExceptions::RegistrationError.new(:unauthorized, Registrations::ErrorCodes::USER_INSUFFICIENT_PERMISSIONS) unless registration.cancelled?
          raise WcaExceptions::RegistrationError.new(:forbidden, Registrations::ErrorCodes::REGISTRATION_CLOSED) if
            registration.cancelled? && !competition.registration_currently_open?

          return # No further checks needed if status is pending
        end

        # Now that we've checked the 'pending' case, raise an error is the status is not cancelled (cancelling is the only valid action remaining)
        raise WcaExceptions::RegistrationError.new(:unauthorized, Registrations::ErrorCodes::USER_INSUFFICIENT_PERMISSIONS) unless
          [Registrations::Helper::STATUS_DELETED, Registrations::Helper::STATUS_CANCELLED].include?(new_status)

        # Raise an error if competition prevents users from cancelling a registration once it is accepted
        raise WcaExceptions::RegistrationError.new(:unauthorized, Registrations::ErrorCodes::ORGANIZER_MUST_CANCEL_REGISTRATION) unless
          registration.permit_user_cancellation?

        # Users aren't allowed to change events when cancelling
        raise WcaExceptions::RegistrationError.new(:unprocessable_entity, Registrations::ErrorCodes::INVALID_REQUEST_DATA) if
          events.present? && registration.event_ids != events
      end
      # rubocop:enable Metrics/ParameterLists

      def validate_update_events!(event_ids, competition)
        raise WcaExceptions::RegistrationError.new(:unprocessable_entity, Registrations::ErrorCodes::INVALID_EVENT_SELECTION) unless
          event_ids.present? && competition.events_held?(event_ids)

        event_limit = competition.events_per_registration_limit
        raise WcaExceptions::RegistrationError.new(:forbidden, Registrations::ErrorCodes::INVALID_EVENT_SELECTION) if event_limit.present? && event_ids.count > event_limit
      end

      def existing_registration_in_series?(competition, target_user)
        return false unless competition.part_of_competition_series?

        other_series_ids = competition.other_series_ids
        other_series_ids.any? do |comp_id|
          Registration.find_by(competition_id: comp_id, user_id: target_user.id)&.might_attend?
        end
      end

      def competitor_qualifies_for_event?(event, qualification, target_user)
        qualification = Qualification.load(qualification)
        qualification.can_register?(target_user, event)
      end
    end
  end
end
