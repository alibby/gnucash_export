#!/usr/bin/env ruby
# Program for reading an sqlite dump of a gnucash data file and exporting
# csv files

require 'rubygems'
require 'hpricot'
require 'csv'
require 'sqlite3'
require 'getoptlong'
require 'ostruct'

def log_msg(msg) 
  $stderr.printf("%s: %s\n", Time.now(), msg)
end

def usage_exit(msg=nil)
  $stderr.puts if msg
  $stderr.puts msg if msg
  $stderr.puts if msg
  
  $stderr.puts %Q{
Usage #{File.basename(__FILE__)} [options]
  --help                  This message
  --db [file]             sqlite database file.
  --outdir [dir]          output directory for csv exports
  --customers             export customers
  --accounts              export accounts
  --transactions          export transactions
  --products              export of distinct invoice line item descriptions and prices
  --vendors               export of employees and vendors
}
  exit 1
end

begin
  opts = GetoptLong.new(
    [ '--help', '-h', GetoptLong::NO_ARGUMENT ],
    [ '--db', '-d', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--outdir', '-o', GetoptLong::REQUIRED_ARGUMENT],
    [ '--invoices', GetoptLong::NO_ARGUMENT ],
    [ '--customers', GetoptLong::NO_ARGUMENT ],
    [ '--accounts', GetoptLong::NO_ARGUMENT ], 
    [ '--transactions', GetoptLong::NO_ARGUMENT ],
    [ '--products', GetoptLong::NO_ARGUMENT ],
    [ '--vendors', GetoptLong::NO_ARGUMENT ]
  )

  @db = 'exports.db'
  @outdir = 'exports'
  @default_tasklist = %w/invoices customers accounts transactions products vendors/
  @tasklist = []

  opts.each do |opt, arg|
    case opt
      when '--help'
        $stderr.puts "Usage #{File.basename(__FILE__)} --outdir=#{@outdir} --db=#{@db}"
        exit 1
      when '--outdir'
        @outdir = arg
      when '--db'
        @db = arg
      else
        task=opt[2..-1]
        if @default_tasklist.include?(task)
          @tasklist << task
        else
          log_msg "I don't know how to export #{task}"
        end
    end
  end
rescue GetoptLong::InvalidOption => e
  usage_exit
end

@tasklist = @default_tasklist if @tasklist.length == 0

if(File.directory?(@outdir))
  log_msg "Found output dirctory #{@outdir}.  Kicking it to /dev/null"
  FileUtils.rm_rf @outdir
end

FileUtils.mkdir @outdir

@db = SQLite3::Database.new( @db )

def full_account_name(guid)
  return "" unless guid && guid.length > 0
  
  result = @db.query_objects %Q{
      SELECT id, name, parent, description, type as "account_type"
      FROM accounts 
      WHERE id = '#{guid}' limit 1; 
  }
  
  result = result.first
  
  return "" if result.account_type == 'ROOT'
  
  name = ""
  name << "#{full_account_name(result.parent)}/" if result.parent && result.parent.length > 0
  name << result.name
  name
end

@db.class.send(:define_method, :query_objects) do |stmt|
  result = self.execute2 stmt
  columns = result.shift.map { |x| x == 'type' ? 'xtype' : x }
  result.map { |row| OpenStruct.new(Hash[ *columns.zip(row).flatten ] ) }
end


def export_transactions
  log_msg("querying for transaction data")
  
  res = @db.execute %Q{ 
    SELECT 
        tr.transactionGuid as "TransactionID", tr.num as "TransactionNumber", tr.date_posted as "DatePosted", tr.date_entered as "DateEntered", 
        tr.description as "Description", ac.id as "AccountName", sp.split_value as "SplitValue", 
        sp.split_quantity as "SplitQuantity", sp.split_lot_guid as "SplitLogGuid"
    FROM transactions tr, transaction_splits sp, accounts ac
    WHERE tr.transactionGuid = sp.transactionGuid AND sp.split_account_guid = ac.id
    ORDER by tr.num;
   }
  
  open("#{@outdir}/transaction.csv",'w') do |fh|
    fh.puts CSV.generate_line(%w/TransactionID TransactionNumber DatePosted DateEntered Description AccountName SplitValue SplitQuantity SplitLogGuid/)

    res.each { |result| 
      result[5] = full_account_name(result[5])
      fh.puts CSV.generate_line(result) 
    }
  end
  
  log_msg "Done exporting transactions"
end
def export_invoices()
  log_msg "querying for invoice data"
  
  res = @db.execute %Q{
    SELECT i.id as 'InvoiceNumber', c.name as 'CustomerName', c.id as "CustomerNumber", i.openedDate as "DateOpened",
           i.postedDate as 'DatePosted', e.date as 'EntryDate', e.description as "EntryDescription", e.qty as "Quantity",
          e.i_price as "EntryPrice", e.qty * e.i_price as "EntryAmount"
    FROM gncinvoices i, customers c, gncentries e
    WHERE c.guid = i.ownerGuid AND e.invoice = i.guid
    ORDER BY i.id
  }

  log_msg "writing #{@outdir}/invoices.csv"
  
  open("#{@outdir}/invocies.csv",'w') do |fh|
    fh.puts CSV.generate_line(%w{InvoiceNumber CustomerName CustomerNumber DateOpened DatePosted EntryDate EntryDescription Quantity EntryPrice})
    res.each do |result|
      fh.puts CSV.generate_line(result)
    end
  end
  
  log_msg "Done exporting invoices"
end
  
def export_customers() 
  log_msg("querying for customer data")
  res = @db.execute %Q{ select id,name,phone,email,address_name,address1,address2,address3,address4 from customers order by id }
  
  open("#{@outdir}/customers.csv",'w') do |fh|
    fh.puts CSV.generate_line(%w/CustomerNumber CustomerName CustomerPhone CustomerEmail AddressName Address1 Address2 Address3 Address4/)
    res.each { |result| fh.puts CSV.generate_line(result) }
  end
  
  log_msg "Done exporting customers"
end
	
def export_vendors() 
  log_msg("querying for vendor and employee data")
  res = @db.execute %Q{ select id, guid, name, address_name, address1, address2, address3 from employees order by id }
  
  open("#{@outdir}/vendors.csv",'w') do |fh|
    fh.puts CSV.generate_line(%w/VendorID VenderGuid VendorName VendorAddressName VendorAddress1 VendorAddress2 VendorAddress3/)
    res.each { |result| fh.puts CSV.generate_line(result) }
  end
  
  log_msg "Done exporting vendors and employees"
end

def export_accounts()
  log_msg("querying for account data")
  res = @db.execute %Q{ select id, name, parent, description, type from accounts order by id }
  
  open("#{@outdir}/accounts.csv",'w') do |fh|
    fh.puts CSV.generate_line(%w/AcountNumber AccountName ParentGuid AccountDescription AccountType/)
    res.each { |result| fh.puts CSV.generate_line(result) }
  end
  
  log_msg "Done exporting accounts"
end

def export_products
  log_msg("Querying for products")
  
  res = @db.execute %Q{ SELECT distinct i_price from gncentries order by i_price; }
  res = res.reject { |x| 
      x = x.first.to_f
      x <= 0 || [5.89, 10, 25, 29.97, 34.8, 35, 48, 50, 57, 64,].include?(x) || x >= 175.35 
    }.map { |x| 
      x = x.first.to_f
      if x == 1
        [ "Discount $1.00", 1.00]
      else
        [ "Consulting Services #{x}", x]
      end
    }
  
  open("#{@outdir}/products.csv", 'w') do |fh|
    fh.puts CSV.generate_line(%w/ProductDescription ProductPrice/)
    res.each { |result| fh.puts CSV.generate_line(result) }
  end
end

@tasklist.each do |task|
  log_msg "Executing #{task}"
  method = "export_#{task}"
  begin
    self.send(method.to_sym)
  rescue NoMethodError => e
    log_msg "I don't seem to have a method called #{method}: #{e}."
    log_msg "This is very likely a developemnt error where new functionalty was added improperly."
  end
end
