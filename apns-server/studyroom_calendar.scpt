-- studyroom_calendar.scpt — pull today's events from macOS Calendar
-- Output: one JSON per line. Dates emitted as ISO components; Python wrapper does epoch.
-- Avoids `date "..."` literal so it works under any locale.

set today_start to (current date)
set time of today_start to 0
set today_end to today_start + (24 * 60 * 60) - 1

set out to ""

tell application "Calendar"
	set cals to calendars
	repeat with cal in cals
		try
			set calName to name of cal as text
			set evs to (every event of cal whose start date ≥ today_start and start date ≤ today_end)
			repeat with ev in evs
				try
					set evId to (uid of ev) as text
					set evTitle to (summary of ev) as text
					set evStart to (start date of ev)
					set evEnd to (end date of ev)
					set evLoc to ""
					try
						set evLoc to (location of ev) as text
					end try
					if evLoc is missing value then set evLoc to ""

					set sStr to my isoOf(evStart)
					set eStr to my isoOf(evEnd)

					set jsonLine to "{" & ¬
						"\"id\":\"" & my escJ(evId) & "\"," & ¬
						"\"title\":\"" & my escJ(evTitle) & "\"," & ¬
						"\"start_iso\":\"" & sStr & "\"," & ¬
						"\"end_iso\":\"" & eStr & "\"," & ¬
						"\"calendar_name\":\"" & my escJ(calName) & "\"," & ¬
						"\"location\":\"" & my escJ(evLoc) & "\"" & ¬
						"}"
					if out is "" then
						set out to jsonLine
					else
						set out to out & linefeed & jsonLine
					end if
				end try
			end repeat
		end try
	end repeat
end tell

return out

on isoOf(d)
	-- "YYYY-MM-DD HH:MM:SS" local time, no timezone marker — wrapper interprets as local.
	set y to year of d as integer
	set mo to (month of d as integer)
	set da to day of d as integer
	set hh to hours of d as integer
	set mm to minutes of d as integer
	set ss to seconds of d as integer
	return (y as text) & "-" & my pad2(mo) & "-" & my pad2(da) & " " & my pad2(hh) & ":" & my pad2(mm) & ":" & my pad2(ss)
end isoOf

on pad2(n)
	set s to (n as integer) as text
	if (count of s) is 1 then return "0" & s
	return s
end pad2

on escJ(s)
	set s to s as text
	set AppleScript's text item delimiters to "\\"
	set parts to text items of s
	set AppleScript's text item delimiters to "\\\\"
	set s to parts as text
	set AppleScript's text item delimiters to "\""
	set parts to text items of s
	set AppleScript's text item delimiters to "\\\""
	set s to parts as text
	set AppleScript's text item delimiters to linefeed
	set parts to text items of s
	set AppleScript's text item delimiters to "\\n"
	set s to parts as text
	set AppleScript's text item delimiters to (ASCII character 13)
	set parts to text items of s
	set AppleScript's text item delimiters to "\\n"
	set s to parts as text
	set AppleScript's text item delimiters to tab
	set parts to text items of s
	set AppleScript's text item delimiters to "\\t"
	set s to parts as text
	set AppleScript's text item delimiters to ""
	return s
end escJ
