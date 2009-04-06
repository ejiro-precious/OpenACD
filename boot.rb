#! /usr/bin/env ruby

require 'socket'

def helpdump
        puts "usage: #{$0} [-c cookiename] [-s shortname | -n longname] [-b bootfile] [-f configfile] [-d]"
		puts "-c defaults to \"ClueCon\"."
		puts "-s and -n override each other.  Defaults to \"-s testme\"."
		puts "-b only needs the file name, ebin is assumed.  Defaults to \"cpx-rel-0.1\"."
		puts "-f defaults to \"single\"."
		puts "-d uses the debug compile."
		puts ""
		puts "If you have not yet run rake (or rake test if you are using"
		puts "-d), erl will fail to start.  If the config file does not"
		puts "exist, a default config is put in it's place.  Feel free"
		puts "to edit it."
        exit
end

$cookie = "ClueCon"
$ebin = 'ebin/'
$nametype = '-sname'
$name = 'testme'
$conf = 'single'
$boot = 'cpx-rel-0.1'

while true do
	case ARGV[0]
		when '--help'
			helpdump
			exit(0)

		when '-c'
			ARGV.shift
			$cookie = ARGV.shift
		
		when '-s'
			ARGV.shift
			$nametype = "-sname"
			$name = ARGV.shift

		when '-n'
			ARGV.shift
			$nametype = "-name"
			$name = ARGV.shift

		when '-b'
			ARGV.shift
			$boot = ARGV.shift

		when '-f'
			ARGV.shift
			$conf = ARGV.shift

		when '-d'
			ARGV.shift
			$ebin = 'debug_ebin/'

		else
			break
	end
end

if ! File.exists?($conf + ".config")
	f = File.new($conf + ".config", "w+")

	hostname = Socket.gethostname
	if $nametype == "-sname"
		hostname = hostname.split('.')[0]
	end
	node = $name + "@" + hostname

	f.puts "%% This file was generated by boot.rb."
	f.puts "%% If you are comfortable editing erlang application configuration scripts"
	f.puts "%% there is no harm in editing the file."
	f.puts "[{cpx, ["
	f.puts "	{nodes, [#{node}]}"
	f.puts "]}]."
	f.close
end

if Dir["Mnesia.#{$name}@*"].length.zero?
	puts "Mnesia directory not found, trying to create the schema"
	`erl -noshell #{$nametype} #{$name} -eval 'mnesia:create_schema([node()]).' -s erlang halt -pa ebin`
end

puts "erl -pa #{$ebin} -pa contrib/mochiweb/ebin/ -setcookie #{$cookie} #{$nametype} #{$name} -config #{$conf} -boot ebin/#{$boot}"
exec "erl -pa #{$ebin} -pa contrib/mochiweb/ebin/ -setcookie #{$cookie} #{$nametype} #{$name} -config #{$conf} -boot ebin/#{$boot}"
#erl -pa ebin/ -pa contrib/mochiweb/ebin/ -setcookie ClueCon -sname testme -config single -boot ebin/cpx-rel-0.1
