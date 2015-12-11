namespace :cron do
  desc "Tasks that should run hourly"
  task hourly: [:finish_projects, :cancel_expired_waiting_confirmation_contributions, :release_transations, :refund_transations, :update_latest_braintree_status]

  desc "Tasks that should run daily"
  task daily: [:update_payment_service_fee, :notify_project_owner_about_new_confirmed_contributions, :move_pending_contributions_to_trash, :deliver_projects_of_week]

  desc "Finish all expired projects"
  task finish_projects: :environment do
    puts "Finishing projects..."
    Project.to_finish.each do |project|
      CampaignFinisherWorker.perform_async(project.id)
    end
  end

  desc "update paypal contributions without a payment_service_fee"
  task update_payment_service_fee: :environment do
    puts "Updating payment service fee..."
    ActiveRecord::Base.connection.execute(<<-EOQ)
    UPDATE contributions SET payment_service_fee = ((regexp_matches(pn.extra_data, 'fee_amount":"(\d*\.\d*)"'))[1])::numeric from payment_notifications pn where contributions.id = pn.contribution_id AND contributions.payment_service_fee is null and contributions.payment_method = 'PayPal' and contributions.state = 'confirmed' and pn.extra_data ~* 'fee_amount';
    EOQ
  end

  desc "Send a notification to all project owners with contributions done..."
  task notify_project_owner_about_new_confirmed_contributions: :environment do
    puts "Notifying project owners about contributions..."
    Project.with_contributions_confirmed_today.each do |project|
      project.notify_owner(
        :project_owner_contribution_confirmed
      )
    end
  end

  desc "Move to deleted state all contributions that are in pending a lot of time"
  task :move_pending_contributions_to_trash => [:environment] do
    puts "Moving pending contributions to trash..."
    Contribution.where("state in('pending') and created_at + interval '6 days' < current_timestamp").update_all({state: 'deleted'})
  end

  desc "Cancel all waiting_confirmation contributions that is passed 4 weekdays"
  task :cancel_expired_waiting_confirmation_contributions => :environment do
    puts "Cancel waiting_confirmation contributions older than 4 working days..."
    Contribution.can_cancel.update_all(state: 'canceled')
  end

  desc "Deliver a collection of recents projects of a category"
  task deliver_projects_of_week: :environment do
    puts "Delivering projects of the week..."
    if Time.now.in_time_zone(Time.zone.tzinfo.name).monday?
      Category.with_projects_on_this_week.each do |category|
        category.deliver_projects_of_week_notification
      end
    end
  end

  desc "Check payment ststus for all projects"
  task check_payments: :environment do
    Project.with_state('online').find_in_batches do |batch|
      batch.each do |project|
        CatarseBraintree::BackerCheckWorker.perform_async(project.id)
      end
    end
  end

  ### CRON Job for release_transations from escrow where escrow status released? ###
  desc "Release transation from escrow"
  task release_transations: :environment do
    puts "Release transation from escrow the hourly..."
    Project.with_state('processing_for_releasing').find_in_batches do |batch|
      batch.each do |project|
        contributions = project.contributions.with_payment_id
          contributions.each do |contribution|
            transaction = Braintree::Transaction.find(contribution.payment_id)
            result = Braintree::Transaction.release_from_escrow(contribution.payment_id)
            contribution.escrow_status = transaction.escrow_status
            contribution.save
          end
        project.finish if contributions.map(&:escrow_status_released?).all?
          puts "Done"
      end
    end
  end
  ### End CRON Job for refund  ###

  ### CRON Job for refund payment for settled or settling state ###
  desc "Refund transation"
  task refund_transations: :environment do
    puts "Refund transation from escrow the hourly..."
    Project.with_state('processing_for_refund').find_in_batches do |batch|
      batch.each do |project|
        CatarseBraintree::BackerCheckWorker.perform_async(project.id)
        contributions = project.contributions.for_refund_transation_braintree_status
        contributions.each do |contribution|
            result = Braintree::Transaction.refund(contribution.payment_id)
            transaction = Braintree::Transaction.find(contribution.payment_id)
            contribution.remote_refund_key = result.transaction.id
            contribution.escrow_status = transaction.escrow_status
            contribution.save
        end
        project.finish if contributions.map(&:escrow_status_refund?).all?
      end
    end
  end
### End CRON Job for refund  ###

### CRON Job for update latest Braintree and escrow state ###
  desc "update Braintree end Escrow latest Status transation"
  task update_latest_braintree_status: :environment do
    puts "update Braintree end Escrow latest Status  the hourly..."
    contributions = Contribution.in_process_braintree_status
    contributions.each do |contribution|
      transaction = Braintree::Transaction.find(contribution.payment_id) rescue nil
      if transaction
        contribution.escrow_status = transaction.escrow_status
        contribution.braintree_status = Contribution::STATUSES[transaction.status.to_sym]
        contribution.save
      end
    end
  end
  ### End CRON Job for update latest Braintree and escrow state ###
end