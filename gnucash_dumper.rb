#!/usr/bin/env ruby
# 
# Program for extracting information from A gnucash data file
# and putting it into an sqlite database

require 'rubygems'
require 'hpricot'
require 'pp'
require 'ostruct'
#require 'gnucash'
require 'csv'
require 'sqlite3'
require 'getoptlong'

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
  --file [file]           Gnucash data file
  --db [file]             sqlite database file.
  
sqlite databse file will be created if it does not exist.
If it exists, it will be wiped out and re-initialized.

}

end

begin
  opts = GetoptLong.new(
    [ '--help', '-h', GetoptLong::NO_ARGUMENT ],
    [ '--file', '-f', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--db', '-d', GetoptLong::REQUIRED_ARGUMENT ]
  )

  @file = 'Tangeis'
  @outdir = 'exports'
  @db = 'exports.db'

  opts.each do |opt, arg|
    case opt
      when '--help'
        usage_exit
      when '--file'
        @file = arg
      when '--db'
        @db = arg
    end
  end
rescue GetoptLong::InvalidOption => e
  usage_exit
end

@init_sql = %Q{
CREATE TABLE account_lots (
	guid text, 
	account text,
	title text, 
	invoiceGuid text);

CREATE TABLE accounts(
	id text, 
	name text, 
	parent text,
	description text, 
	type text, 
	commodity_scu text);

CREATE TABLE customers (
	guid text,
	id text, 
	name text, 
	phone text,
	email text, 
	fax text, 
	address_name text, 
	address1 text, 
	address2 text, 
	address3 text, 
	address4 text, 
	shipping_name text, 
	shipping_address1 text, 
	shipping_address2 text, 
	shipping_address3 text, 
	shipping_address4 text, 
	shipping_phone text,
	shipping_fax text, 
	shipping_email text);

CREATE TABLE employees (
	guid text,
	id text,
	name text,
	address_name text, 
	address1 text,
	address2 text, 
	address3 text);

CREATE TABLE gncentries(
	guid text,
	date text,
	entered text, 
	description text, 
	action text, 
	qty text, 
	i_acct text, 
	i_price numeric, 
	invoice text , 
	i_disc_type text, 
	i_disc_how text, 
	i_taxable text, 
	i_taxincluded text);

CREATE TABLE gncinvoices(
	guid text, 
	id text, 
	ownertype text,
	ownerGuid,
	openedDate text,
	postedDate text,
	active text,
	billingId text, 
	posttxn text,
	postlot text, 
	postacc text);

CREATE TABLE transaction_slots (
	transactionGuid text,
	trans_txn_type text,
	trans_date_due text,
	invoiceGuid text,
	trans_read_only text,
	notes text
);

CREATE TABLE transaction_splits (
	transactionGuid text,
	splitId text,
	action text,
	reconciled_state text,
	split_value text,
	split_quantity text,
	split_account_guid text,
	split_lot_guid text);
	
CREATE TABLE transactions (
	transactionGuid text,
	num text,
	date_posted text,
	date_entered text,
	description text);
}



unless(File.file?(@file))
  log_msg "Can't find gnucash data file called #{@file}"
  exit 1
end

# Setup the database, removing it if it exists.  So we always
# start with a good, new car smelling empty database:

if(File.file?(@db))
  log_msg "Found existing db in #{@db}.  Removing"
  FileUtils.rm(@db)
end

db = SQLite3::Database.new( @db )
db.execute_batch(@init_sql)

log_msg "DB Created"
 
log_msg "Opening gnucash data file #{@file}, and parsing...."

@seds = %q{ sed 's/<act:parent type="guid">/<act:therents type="guid">/g' | sed 's/<\/act:parent>/<\/act:therents>/g' }
@h = Hpricot(IO.popen(%Q{gunzip -c -S "" #{@file} | #{@seds}}))

log_msg "Done parsing data file."

def each(xpath,&block)
  @h.search(xpath).each { |e| yield e }
end

def divide_number(elem)
  it = elem.respond_to?(:inner_text) ? elem.inner_text : elem
  return 0.0 unless it && it.length > 0 && it != 0
  eval("#{elem.inner_text}.to_f")
end

  
log_msg "Extracting invoice entries"

each("//gnc:gncentry") do |e|
  db.execute("insert into gncentries values(?,?,?,?,?,?,?,?,?,?,?,?,?)",[
      (e/"entry:guid").inner_text,
      (e/"entry:date"/"ts:date").inner_text,
      (e/"entry:entered"/"ts:date").inner_text,
      (e/"entry:description").inner_text,
      (e/"entry:action").inner_text,
      divide_number((e/"entry:qty")),
      (e/"entry:i-acct").inner_text,
      divide_number((e/"entry:i-price")),
      (e/"entry:invoice").inner_text,
      (e/"entry:i-disc-type").inner_text,
      (e/"entry:i-disc-how").inner_text,
      (e/"entry:i-taxable").inner_text,
      (e/"entry:i-taxincluded").inner_text
    ]
  )
end

log_msg "Invoice entry extraction complete."

log_msg "Extracting transactions"

each("//gnc:transaction") do |txn|
	txnId = (txn/"trn:id").inner_text
	txnNum = (txn/"trn:num").inner_text
	txn_date_posted = (txn/"trn:date-posted"/"ts:date").inner_text
	txn_date_entered = (txn/"trn:date-entered"/"ts:date").inner_text
	txn_description = (txn/"trn:description").inner_text
	slotTransactionType  = ""
	slotTransDue = ""
	slotInvoiceGuid ="" 
	slotTransReadOnly =""
	slotNote = ""
	db.execute("insert into transactions values(?,?,?,?,?)", [txnId,txnNum,txn_date_posted,txn_date_entered,txn_description])
			
	(txn/"trn:splits"/"trn:split").each do |splits|
		splitGuid = (splits/"split:id").inner_text
		splitAction = (splits/"split:action").inner_text
		splitReconciledState = (splits/"split:reconciled-state").inner_text
		splitValue =  divide_number( (splits/"split:value") )
		splitQty =  divide_number( (splits/"split:quantity") )
		splitAccount = (splits/"split:account").inner_text
		splitLotGuid = (splits/"split:lot").inner_text
		
		db.execute("insert into transaction_splits values(?,?,?,?,?,?,?,?)",[txnId,splitGuid,splitAction,splitReconciledState,splitValue,splitQty,splitAccount,splitLotGuid])
	end
	
  (txn/"trn:slots"/"slot").each do |slot|
    slotKey = (slot/"slot:key").first.inner_text
    case slotKey
      when "trans-txn-type"
        slotTransactionType = (slot/"slot:value").inner_text	
      when "trans-date-due" 
        slotTransDue = (slot/"slot:value"/"ts:date").inner_text	
      when "gncInvoice"
        slotInvoiceGuid = (slot/"slot:value"/"slot"/"slot:value").inner_text
      #	puts "Invoice: #{slotInvoiceGuid}"
      when "trans-read-only"
        slotTransReadOnly = (slot/"slot:value").inner_text
      when "notes"
        slotNote = (slot/"slot:value").inner_text
      when 'invoice-guid'
        # this is ok... do nothing. .. got it above.
      else
        # puts "#{slotKey} ."
      puts "Unexpected Slot type #{slotKey} -- #{txnId}"
    end
  end
  
  db.execute("insert into transaction_slots values(?,?,?,?,?,?)",
    [
      txnId,slotTransactionType,slotTransDue,slotInvoiceGuid,slotTransReadOnly,slotNote
    ]
  )
end

log_msg "Transaction extraction complete."


log_msg "Extracting accounts"

each("//gnc:account") do |e|
  db.execute( "insert into accounts values(?,?,?,?,?,?)" , 
    [(e/"act:id"),
    (e/"act:name"),
    (e/"act:therents"),
    (e/"act:description"),
    (e/"act:type"),
    (e/"act:commodity-scu")
  ].map {|x| x.inner_text })
  
  actId = (e/"act:id").inner_text
  
  (e/"gnc:lot").each do |lot|
  	lotId =  nil
  	lotId = (lot/"lot:id").inner_text
  	lotTitle  = nil
  	lotInvoiceGuid = nil
  	(lot/"lot:slots"/"slot").each do |slot|
      slotType = (slot/"slot:value").first[:type]
      case slotType
        when "string"
          lotTitle = (slot/"slot:value").inner_text
        when "frame"
         lotInvoiceGuid = (slot/"slot:value"/"slot"/"slot:value").inner_text
      end
    end
    # log_msg "#{(e/"act:name").inner_text} -- #{lotTitle} :: and :: #{lotInvoiceGuid}"
    db.execute("insert into account_lots values(?,?,?,?) ",[lotId,actId,lotTitle,lotInvoiceGuid])
  end
end

log_msg "Account extraction complete."


log_msg "Extracting customers"

each("//gnc:gnccustomer") do |e|
  db.execute( "insert into customers values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",[
  (e/"cust:guid"),
  (e/"cust:id"),
  (e/"cust:name"),
  (e/"cust:addr"/"addr:phone"),
  (e/"cust:addr"/"addr:email"),
  (e/"cust:addr"/"addr:fax"),
  (e/"cust:addr"/"addr:name"),
  (e/"cust:addr"/"addr:addr1"),
  (e/"cust:addr"/"addr:addr2"),
  (e/"cust:addr"/"addr:addr3"),
  (e/"cust:addr"/"addr:addr4"),
  (e/"cust:shipaddr"/"addr:name"),
  (e/"cust:shipaddr"/"addr:addr1"),
  (e/"cust:shipaddr"/"addr:addr2"),
  (e/"cust:shipaddr"/"addr:addr3"),
  (e/"cust:shipaddr"/"addr:addr4"),
  (e/"cust:shipaddr"/"addr:phone"),
  (e/"cust:shipaddr"/"addr:fax"),
  (e/"cust:shipaddr"/"addr:email")
  ].map {|x| x.inner_text })
end

log_msg "Customer extraction complete"

log_msg "Extracting employees and vendors"

each("//gnc:gncvendor") do |e|
  next if ['101','106'].include?((e/"vendor:id").inner_text)
  db.execute("insert into employees values(?,?,?,?,?,?,?)",[
      (e/"vendor:guid"),
      (e/"vendor:id"),
      (e/"vendor:name"),
      (e/"vendor:addr"/"addr:name"),
      (e/"vendor:addr"/"addr:addr1"),
      (e/"vendor:addr"/"addr:addr2"),
      (e/"vendor:addr"/"addr:addr3")
    ].map {|x| x.inner_text.gsub(/,\s*LLC$/, '')})
end

log_msg "Employee and vendor extraction complete."

log_msg "Extracting invoices"

each("//gnc:gncinvoice") do |e|
  db.execute("insert into gncinvoices values(?,?,?,?,?,?,?,?,?,?,?)",[
      (e/"invoice:guid"),
      (e/"invoice:id"),
      (e/"invoice:owner"/"owner:type"),
      (e/"invoice:owner"/"owner:id"),
      (e/"invoice:opened"/"ts:date"),
      (e/"invoice:posted"/"ts:date"),
      (e/"invoice:active"),
      (e/"invoice:billing_id"),
      (e/"invoice:posttxn"),
      (e/"invoice:postlot"),
      (e/"invoice:postacc"),
    ].map {|x| x.inner_text.gsub(/,\s*LLC$/, '')}
  )
end

log_msg "Invoice extraction complete."

