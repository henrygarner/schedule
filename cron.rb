require 'date'

class Cron
  
  attr_reader :time
  
  def initialize(fields, time = time_without_seconds)
    @fields     = fields
    array       = fields.split(' ')
    raise 'Cron expression does not have 5 fields' if array.size != 5
    
    @minutes    = Field.new array[0], 0..59
    @hours      = Field.new array[1], 0..23
    @monthdays  = Field.new array[2], 1..31
    @months     = Field.new array[3], 1..12
    @weekdays   = Field.new array[4], 0..6
    
    self.cursor = self.time = time_without_seconds
    
    raise 'Cron expression will never match' if [1,3,5,7,8,10,12].all? { |month| !@months.values.include? month } and @monthdays.values == [31]
    raise 'Cron expression will never match' if @months.values == [2] and @monthdays.values.all? { |day| day > 29 }
  end
  
  def matches?(time = time_without_seconds)
    self.cursor, before_scan = time, cursor_array
    scan! :ignore_current => false
    cursor_array == before_scan
  end
  
  def before(time)
    self.cursor = time
    self.previous
  end
  
  def after(time)
    self.cursor = time
    self.next
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
    self.cursor = time
    scan! :direction => :up, :ignore_current => true
    cursor
  end
  
  def previous
    self.cursor = time
    scan! :direction => :down
    cursor
  end
  
  def between(time, end_time)
    time, end_time = [time, end_time].sort
    self.time = time
    matches = [(time if matches?(time))].compact
    loop do
      next!
      self.time > end_time ? break : matches << self.time
    end
    matches
  end
  
  def time=(time)
    @time = time_without_seconds time
  end
  
  def next!
    self.time = self.next
  end
  
  def to_s
    @fields
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
   # one level higher with 'should rollover' set to true.
   # This causes the value one level up to be set to the next or previous value,
   # and all finer-grained quantities (eg hours and minutes) are
   # set to their minimum or maximum value.
   # A match is always found at the year level and the function returns.
   
   # If months or years (level 3 or 4) are altered then the function
   # calls itself back at level 2 (days) since a different month or year
   # may cause the calendar days to require re-matching.
   # This is accomplished with [level + 1, 2].min

   # level 0 = minutes, 1 = hours, 2 = days, 3 = months, 4 = years
   def scan!(options = {})
     direction      = options[:direction] || :up
     level          = options[:level].to_i
     ignore_current = options[:ignore_current]
     
     return if level > 4
     
     comparison, rollover = (direction == :up ? ['>','min'] : ['<','max'])
     matches              = time_methods[level].call
     matches = matches.reverse unless direction == :up
     
     if ignore_current or not matches.include? cursor_array[level]
       if found = matches.detect { |is| is.send comparison, cursor_array[level] }
         
         cursor_array[level] = found
         # We set the cursor in reverse order so that months and years are altered first,
         # since the days method will need to use these new values to calculate its response.
         (0...level).to_a.reverse.each { |i| cursor_array[i] = time_methods[i].call.send rollover }
         
         scan! options.merge(:level => level + 1, :ignore_current => false)
       else
         scan! options.merge(:level => level + 1, :ignore_current => true)
       end
     else
       scan! options.merge(:level => level + 1, :ignore_current => false)
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
   # month and year. This provides the number of days in the month and the weekday of the first day
   # With these two facts we can construct an array of matching calendar days applying the logic given above.

   def days
     first_day = Date.civil cursor_array[4], cursor_array[3]
     last_day = ((first_day >> 1) - 1).day
     weekday_adjustment = 1 - first_day.wday
     
     [  ([0,7,14,21,28].collect do |week_adjustment|
       
        # Loop through weeks turning the weekdays into calendar days by adding the week_adjustment
        # and weekday_adjustment. weekday_adjustment is 1 to -5 depending if the first weekday
        # of the month is Monday to Sunday respectively. Where month begins on Monday, no adjustment is needed
        # since week day 1 is also calendar day 1. If month begins on Tuesday, adjustment is -1
        # since week day 2 is calendar day 1 etc.
        
          weekdays.values.collect { |day| (day + week_adjustment + weekday_adjustment) % 35 }
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

