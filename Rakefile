
desc "Export"
task :export do
  `./gnucash_export.rb`
end

desc "Zip exports"
task :zip => :export do
  `zip -r exports.zip exports`
end

desc "Clean up.."
task :clean do 
  (Dir['*.db'] + Dir['*.csv']).each { |f| rm f }
  rm_rf 'exports'
  rm_rf 'exports.zip'
end

