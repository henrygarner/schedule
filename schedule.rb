require 'date'

class Schedule
  
  attr_reader :reference, :expression
  
  def initialize(expression, time = time_without_seconds)
    @expression = expression
    array       = expression.split(' ')
    
    raise 'expression does not have 5 fields' if array.size != 5
    
    @minutes    = Field.new array[0], 0..59
    @hours      = Field.new array[1], 0..23
    @monthdays  = Field.new array[2], 1..31
    @months     = Field.new array[3], 1..12
    @weekdays   = Field.new array[4], 0..6
    
    raise 'expression will never match' if weekdays.wildcard and [1,3,5,7,8,10,12].all? { |month| !months.include? month } and monthdays == [31]
    raise 'expression will never match' if weekdays.wildcard and months == [2] and monthdays.all? { |day| day > 29 }
    
    self.reference = time
  end
  
  def matches?(time)
    # We compare the time representations as arrays to eliminate mismatches
    # due to sub-minute differences.
    time.to_a[1..5] == before(time).to_a[1..5]
  end
  alias_method :===, :matches?
  
  def before(time)
    self.cursor = time
    scan! :direction => :down
    cursor
  end
  
  def after(time)
    self.cursor = time
    scan! :direction => :up, :skip_current => true
    cursor
  end
  
  def after_now
    after time_without_seconds
  end
  
  def before_now
    before time_without_seconds
  end
  
  def matches_now?
    matches? time_without_seconds
  end
  
  def next
    after reference
  end
  
  def previous
    before reference
  end

  def each(start_time = reference)
    self.cursor = start_time
    yield cursor if matches? cursor
    loop { yield after cursor }
  end
  
  def while(start_time = reference)
    each(start_time) { |time| break unless yield time }
  end
  
  def upto(end_time, start_time = reference)
    timetable = []
    each(start_time) { |time| time <= end_time ? (block_given? ? yield(time) : timetable << time) : break }
    timetable unless block_given?
  end
  
  def between(start_time, end_time)
    timetable = []
    upto(end_time, start_time) { |time| timetable << time }
    timetable
  end

  def next!
    self.reference = self.next
  end
  
  def reference=(time)
    @reference = time_without_seconds time
  end

  private
  
  attr_reader :weekdays, :monthdays
  
  def time_without_seconds(time = Time.now)
    time - time.sec
  end
  
  def cursor
    Time.gm @cursor_array[4], @cursor_array[3], @cursor_array[2], @cursor_array[1], @cursor_array[0]
  end
  
  def cursor=(time)
    @cursor_array = time.to_a[1..5]
  end
  
  def cursor_array
    @cursor_array
  end
  
   # Recursive function to resolve cursor to the next or previous match.
   # An array is used rather than a Time object for performance reasons.
   # Starting at level 0 (minutes), function works its way up to level 4 (years).
   
   # If the current value at a given level matches, no action is taken
   # and the function calls itself one level higher.
   # If a match is found within the current frame (eg the same day if 
   # searching for hours), the function replaces the value for the match
   # and calls itself one level higher as before.
   # If no match is found within the current frame (eg hours will only match
   # in a subsequent or prior day), then the function calls itself 
   # one level higher with 'skip current' set to true.
   # This causes the value one level up to be set to the next or previous value,
   # and all finer-grained quantities (eg hours and minutes) are
   # set to their minimum or maximum value.
   # The function returns after years are processed.

   # level 0 = minutes, 1 = hours, 2 = days, 3 = months, 4 = years
   def scan!(options = {})
     direction    = options[:direction] || :up
     level        = options[:level].to_i
     skip_current = options[:skip_current]
     
     return if level > 4
     
     comparison, rollover = (direction == :up ? ['>','min'] : ['<','max'])
     matches              = time_methods[level].call
     matches = matches.reverse unless direction == :up
     
     if skip_current or not matches.include? cursor_array[level]
       if found = matches.detect { |is| is.send comparison, cursor_array[level] }
         
         cursor_array[level] = found
         # We set the cursor in reverse order so that months and years are altered first,
         # since the days method will need to use these new values to calculate its response.
         (0...level).to_a.reverse.each { |i| cursor_array[i] = time_methods[i].call.send rollover }
         
         scan! options.merge(:level => level + 1, :skip_current => false)
       else
         scan! options.merge(:level => level + 1, :skip_current => true)
       end
     else
       scan! options.merge(:level => level + 1, :skip_current => false)
     end
   end

   def minutes
     @minutes.values
   end

   def hours
     @hours.values
   end

   def months
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
   
   # Below function uses the position of the current cursor to create a Date object representing
   # month and year. This provides the number of days in the month and the weekday of the first day.
   # With these two facts we can construct an array of matching calendar days applying the logic given above.

   def days
     first_day = Date.civil cursor_array[4], cursor_array[3]
     last_day = ((first_day >> 1) - 1).day
     weekday_adjustment = 1 - first_day.wday
     
     [  ([0,7,14,21,28].map do |week_adjustment|
       
        # Loop through weeks turning the weekdays into calendar days by adding the week_adjustment
        # and weekday_adjustment. weekday_adjustment is 1 to -5 depending if the first weekday
        # of the month is Monday to Sunday respectively. Where month begins on Monday, no adjustment is needed
        # since week day 1 is also calendar day 1. If month begins on Tuesday, adjustment is -1
        # since week day 2 is calendar day 1 etc.
        
          weekdays.values.map { |day| (day + week_adjustment + weekday_adjustment) % 35 }
        end.flatten.select { |day| day >= 1 and day <= last_day } unless not monthdays.wildcard and weekdays.wildcard),
        
        (monthdays.values.select { |day| day >= 1 and day <= last_day } unless not weekdays.wildcard and monthdays.wildcard)
      ].flatten.compact.uniq.sort
   end

   def years
     [cursor_array[4] - 1, cursor_array[4], cursor_array[4] + 1]
   end
  
  def time_methods
    [method(:minutes), method(:hours), method(:days), method(:months), method(:years)]
  end
  
  class Field
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

