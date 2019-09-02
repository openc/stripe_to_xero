#!/usr/bin/env ruby

require 'csv'
require 'date'
require 'stripe'
# require 'byebug'

PER_PAGE = 100
def cents_to_dollars(value)
  if value != 0
    val = value.to_s[0..-3] + "." + value.to_s[-2..-1]
    val.to_f
  else
    value
  end
end

def xero_date(date_obj)
  if !date_obj.respond_to? :year
    date_obj = Time.at date_obj
  end
  date = "#{date_obj.year}-#{"%02d" % date_obj.month}-#{"%02d" % date_obj.day}"
end

Stripe.api_key = ENV['STRIPE_SECRET']
bank_name = ENV['BANK_NAME'] || "Royal Bank of Scotland"
given_limit = ENV['STX_COUNT'] || 200
limit = given_limit.to_i
output_file = 'xero.csv'

puts "gathering last #{limit} charges"
pages = (limit - 1)/PER_PAGE + 1 # we can get max 100 per page, so number of pages is the number of pages into the *next* 100
starting_after = nil
charges = []
pages.times do |page_no|
  call_limit = [limit,PER_PAGE].min
  puts "Page #{page_no+1}: from #{page_no * PER_PAGE} to #{page_no * PER_PAGE + call_limit - 1}"
  charges += Stripe::Charge.all(limit: call_limit, starting_after: starting_after, expand: ['data.customer']).to_a
  # debugger
  limit -= PER_PAGE
  starting_after = charges.last
end
puts "done!"

limit = given_limit.to_i
puts "gathering last #{limit} transfers"
transfers = Stripe::Transfer.all(limit: limit)
puts "done"

def charge_description(charge, charge_type="charge")
  if charge.customer.respond_to? :deleted
    description = "#{charge_type} from deleted customer id: #{charge.customer.id}"
  else
    customer_description = charge.customer.metadata['legal_name'] ? "#{charge.customer.metadata['legal_name']} (#{charge.customer.description})" : charge.customer.description
    description = "#{charge_type} from #{customer_description} / #{charge.customer.email}"
  end
end

def process_refunds(charge, csv)
  if charge.amount_refunded > 0
    date = xero_date charge.created
    if charge.customer
      payee = charge.customer.id
      description = charge_description(charge, "refund")
    else
      payee = "nil customer"
      description = "Refund from nil customer"
    end
    amount = -(cents_to_dollars charge.amount_refunded)
    reference = charge.balance_transaction
    type = "Debit"
    csv << [date, description, amount, reference, type, payee]
  end
end

puts "Writing xero.csv"
CSV.open(output_file, 'wb', row_sep: "\r\n") do |csv|
  csv << ['Transaction Date','Description', 'Transaction Amount', 'Reference', 'Transaction Type', 'Payee']
  transfers.each do |transfer|
    if transfer.status == "paid"
      date = xero_date transfer.date
      description = "Transfer from Stripe"
      amount = -cents_to_dollars(transfer.amount)
      reference = transfer.id
      type = "Transfer"
      payee = bank_name
      fees = - cents_to_dollars(transfer.summary.charge_fees + transfer.summary.refund_fees)
      fee_adjustment = cents_to_dollars(transfer.summary.adjustment_gross - transfer.summary.adjustment_fees)
      description2 = "Stripe fees"
      type2 = "Debit"
      payee2 = "Stripe"

      csv << [date,description,amount,reference,type,payee]
      csv << [date,description2,fees,reference,type2,payee2]
      if fee_adjustment != 0
        csv << [date, 'Stripe fee adjustment', fee_adjustment, reference, "credit", "Stripe"]
      end
    end
  end
  charges.each do |charge|
    # debugger
    if charge.paid
      date = xero_date charge.created
      if charge.customer
        payee = charge.customer.id
        description = charge_description(charge)
      else
        payee = charge.card.name
        description = "Payment from cardholder: #{payee}"
      end
      amount = cents_to_dollars charge.amount
      if charge.currency != 'gbp'
        # store amount in original currency
        description += " #{charge.currency.upcase}#{amount}"
        # and change to amount in local currency
        # with thanks to https://gist.github.com/siddarth/6241382
        balance_transaction = Stripe::BalanceTransaction.retrieve(charge.balance_transaction)
        amount = cents_to_dollars(balance_transaction.amount)
      end
      reference = charge.id
      type = "Credit"

      csv << [date,description,amount,reference,type,payee]
    end
    process_refunds(charge, csv)
  end
end
puts "complete!"
