#/usr/bin/env ruby

require "pg"
require "eventmachine"
require "json"
require "uri"
require "cgi"
require "websocket-eventmachine-client"

$downdetector = 1

def parseText(text)
        # Perform Unescaping and encoding transform
        text = CGI.unescape(text.force_encoding('iso-8859-1')).encode('utf-8')

        begin
                # Attempt to replace unicode entities if possible
                newtext = text.gsub(/%u([0-9A-F]{4})/i){$1.hex.chr(Encoding::UTF_8)}
                text = newtext
        rescue Excption => e
                puts ">>> Error occured in codepoint substitution"
        end

        # Finally replace HTML entities
        return CGI.unescapeHTML(text)
end


# Connect to DB

pgdb = PG::Connection.new(:host => 'localhost', :port => 5432, :dbname => 'oneirros', :user => 'oneirros', :password => '')
pgdb.prepare('getotp', 'SELECT * FROM public.rivalcheck WHERE otp = $1')
pgdb.prepare('clearotp', 'DELETE FROM public.rivalcheck WHERE otp = $1')
pgdb.prepare('clearbind', 'DELETE FROM public.rivalmapping WHERE rrid = $1')
pgdb.prepare('binduser', 'INSERT INTO public.rivalmapping (uid, rrid) VALUES ($1, $2)')

while true
	EventMachine.run do
		rrws = WebSocket::EventMachine::Client.connect(:uri => 'http://static.rivalregions.com:8880/socket.io/?EIO=3&transport=websocket')
		rrws.onopen do
			rrws.send "2probe"
		end

		rrws.onmessage do |msg, type|
			if msg == "40"
				puts ">>> Connected"
				rrws.send "42[\"rr_room\",\"w133742w_0\"]"
			elsif msg[0] == "3" 
				$downdetector = $downdetector - 1
			elsif msg[0..1] == "42"
				begin
					info = JSON.parse(JSON.parse(msg[2..-1])[1])
					text = parseText(info["text"])
					text.strip!
					name = parseText(info["name"])

					if text.length == 40
						pgdb.transaction do |transac|
							result = transac.exec_prepared('getotp', [ text ])
					
							# Check if we have a matching user
							founduid = "none"
							result.each do |row|
								founduid = row["uid"]
							end			
						
							if founduid.length != "none"
								transac.exec_prepared('clearotp', [ text ])
								transac.exec_prepared('clearbind', [ info["id"] ])
								transac.exec_prepared('binduser', [ founduid, info["id"] ])
								puts "Mapped: #{founduid} to #{info['id']}" 
							end

						end		
					end
				rescue Exception => e
					puts ">>> Exception: #{e}"
				end
			end
		end

		EventMachine.add_periodic_timer(20) do
			rrws.send "2"
		end

		EventMachine.add_periodic_timer(30) do
			$downdetector = $downdetector + 1
			if ($downdetector < 0) 
				$downdetector = 0
			end
			if ($downdetector > 4)
				EventMachine.stop_event_loop
			end
		end
	end
end
