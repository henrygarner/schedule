class Cron
  
  attr_reader :weekdays, :monthdays
  
  def initialize(fields)
    @fields     = fields
    array       = fields.split(' ')
    raise 'Cron expression does not have 5 fields' if array.size != 5
    
    @minutes    = Field.new array[0], 0..59
    @hours      = Field.new array[1], 0..23
    @monthdays  = Field.new array[2], 1..31
    @months     = Field.new array[3], 1..12
    @weekdays   = Field.new array[4], 0..6
    
    raise 'Cron expression will never match' if [1,3,5,7,8,10,12].all? { |month| !@months.values.include? month } and @monthdays.values == [31]
    raise 'Cron expression will never match' if @months.values == [2] and @monthdays.values.all? { |day| day > 29 }
  end
  
  def before(time)
    minute, hour, day, month, year = scan(time.to_a[1..5], :down)
    Time.gm year, month, day, hour, minute
  end
  
  def after(time)
    minute, hour, day, month, year = scan(time.to_a[1..5], :up)
    Time.gm year, month, day, hour, minute
  end
  
  def previous
    before Time.now
  end
  
  def next
    after Time.now
  end
  
  def between(time, end_time)
    triggers, rollover = [], false
    loop do
      minute, hour, day, month, year = scan(time.to_a[1..5], :up, 0, rollover)
      time = Time.gm year, month, day, hour, minute
      rollover = true # If the loop is continued, we need subsequent scans to ignore the current match
      time > end_time ? break : triggers << time
    end
    triggers
  end

  def to_s
    @fields
  end

  protected
  
   # Recursive function to resolve time array to the next or previous match

   # If a value is included in the array of matches for a particular level,
   # the function calls iteself at one level higher.
   # If a value is excluded from the array of matches for a level,
   # the array is searched for the subsequent match. If one is found,
   # this value is substituted in the time array and the function
   # calls itself one level higher.
   # If no match is found, then a 'rollover' is required, and the function
   # calls itself a level higher with 'should rollover' set to true.
   # This causes the upper level to search for a subsequent match,
   # rather than check if the existing value is included.
   # If one is found, this is substituted in the time array and
   # all previous values are set to the upper or lower end of their range
   # (depending on whether we are moving forwards or backwards in time)
   # If none is found, the function calls itself yet again one level
   # higher with 'should rollover' set to true.
   # This continues until a match is found. At the final level, years,
   # a match is always found if not before, and the process halts.

   # level 0 = minutes, 1 = hours, 2 = days, 3 = months, 4 = years
   def scan(time_array, direction = :up, level = 0, should_rollover = false)
     
     matches = time_methods[level].call(time_array)
     matches.reverse! unless direction == :up
     comparison, rollover = (direction == :up ? ['>','min'] : ['<','max'])
     
     if !matches.include?(time_array[level]) or should_rollover
       if found = matches.detect { |is| is.send comparison, time_array[level] }
         time_array[level] = found
         (0...level).each { |i| time_array[i] = time_methods[i].call(time_array).send rollover }
         scan time_array, direction, [level + 1, 2].min
       else
         scan time_array, direction, level + 1, true
       end
     else
       scan time_array, direction, level + 1 if level < 4
     end
     
     time_array
   end

   def minutes(time_array)
     @minutes.values
   end

   def hours(time_array)
     @hours.values
   end

   def months(time_array)
     @months.values
   end

   # There are two different ways of specifying days in Cron: by day of month (1-31) or day of week (0-6).
   # You are allowed to restrict either, neither or both. In each case the behaviour is slightly different.
   # If neither is restricted, we always match any day.
   # If just one is restricted, we match only this.
   #   (we ignore the unrestricted field since this would match any day and override desired behaviour).
   # If both are restricted, we want to match one or the other (we don't mind which).

   # Example
   # 0 0 1 * *
   #   Matches 00:00 on the first day of every month
   # 0 0 1 * 5
   #   Matches 00:00 on the first day of every month, OR every Friday
   # 0 0 * * 5
   #   Matches 00:00 every Friday

   # The below function returns the calendar days which should be matched.
   # This is accomplished by looking at both the monthdays and weekdays specification and applying the logic above.
   # In order to turn weekdays into calendar days, the function takes a time array which specifies
   # the month and year.
   # An array of matching calendar days for this month and year is returned.

   def days(time_array)
     first_day = Date.new time_array[4], time_array[3]
     last_day = first_day.end_of_month.day
     wday_adjustment = ((first_day.wday - 1) % 7)
     
     [  ((0..5).collect do |week_number|
        # Loop through five weeks turning the weekdays into calendar days by adding (week_number * 7)
        # and adjusting with the wday_adjustment. wday_adjustment is 0 to -6 depending if the first weekday
        # of the month is Monday to Sunday respectively. Where month begins on Monday, no adjustment is needed
        # since week day 1 is also calendar day 1. If month begins on Tuesday, adjustment is -1
        # since week day 2 is calendar day 1 etc.
          weekdays.values.collect { |day| (week_number * 7) + day - wday_adjustment }
        end.flatten.select { |day| day >= 1 and day <= last_day } unless not monthdays.wildcard and weekdays.wildcard),
        
        (monthdays.values.select { |day| day >= 1 and day <= last_day } unless not weekdays.wildcard and monthdays.wildcard)
      ].flatten.compact.uniq.sort
   end

   def years(time_array)
     [time_array[4] - 1, time_array[4], time_array[4] + 1]
   end
  
  def time_methods
    [method(:minutes), method(:hours), method(:days), method(:months), method(:years)]
  end
  
  class Field
    include Enumerable
    WEEKDAYS = %w(SUN MON TUE WED THU FRI SAT)
    attr_reader :values, :wildcard
    def initialize(field, range)
      @wildcard = false
      
      @values = field.split(',').map do |part|
        case part
        when '*'
          @wildcard = true
          range.to_a
        when /(\d+)-(\d+)/
          ( $1.to_i .. $2.to_i ).to_a
        when /(\*|\d+)\/(\d+)/
          puts 'Cycling...'
          cycle, index = $2.to_i, -1
          ( ($1 == '*' ? range.first : $1.to_i) .. range.last ).to_a.select { (index += 1) % cycle == 0 }
        when /(SUN|MON|TUE|WED|THU|FRI|SAT)/i
          WEEKDAYS.index($1.upcase)
        else
          part.to_i
        end
      end.flatten.uniq.sort
      
      raise 'field out of range' unless @values.all? { |value| range.include? value }
    end

  end

end

