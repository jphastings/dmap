require 'forwardable'
require 'stringio'
require 'delegate'

# If you plan on extending this module (like you'll need to if you want extra tags available)
# make sure you don't use any class names with four letters in. It saves a bit of processor time
# if I don't have to remove them.
module DMAP
  # Represents any DMAP tag and its content.
  # Will have methods appropriate to the dmap specified
  class Element
    attr_reader :tag
    attr_reader :real_class
    
    # Accepts a string or an IO. The first four bytes (in either case) should be the
    # tag you wish to make.
    #
    # If you have a big dmap file this is your lucky day, this class only
    # processes the parts needed for any queries you're making, so its all on-the-fly.
    #
    # NB. if you specify `content` while passing a dmap tag you will overwrite anything
    # that was in the dmap!
    def initialize(tag_or_dmap,new_content = nil)      
      # Assume we have an IO object, if this fails then we probably have a string instead
      begin
        @tag = tag_or_dmap.read(4).upcase
        @io = tag_or_dmap if new_content.nil?
      rescue NoMethodError
        @tag = tag_or_dmap[0..3].upcase
      end
      
      # Find out the details of this tag
      begin
        type,@name = DMAP.const_get(@tag)
      rescue NameError
        raise NameError, "I don't know how to interpret the tag '#{@tag}'. Please extend the DMAP module!"
      end
      
      self.send("parse_#{type}",new_content)
      fudge = @real_class
      eigenclass = class<<self; self; end
      eigenclass.class_eval do
        extend Forwardable
        def_delegators :@real_class,*fudge.methods - ['__send__','__id__','to_dmap']
        def inspect
          "<#{@tag}: #{@real_class.inspect}>"
        end
      end
    end
    
    def is_dmap?
      true
    end
    
    def close_stream
      begin
        @io.close
      rescue NoMethodError
        # There was no IO or its already been closed
      end
    end
    
    # Adds the tag to a request to create the dmap
    def to_dmap
      "#{@tag.downcase}#{@real_class.to_dmap}"
    end
    
    private
    
    def parse_string(content)
      begin
        @real_class = String.new(content || @io.read(@io.read(4).unpack("N")[0])) # FIXME: Should be Q?
      rescue NoMethodError
        @real_class = String.new
      end
    end
    
    def parse_list(content)
      @real_class = Array.new(content || @io || [])
    end
    
    def parse_number(content,signed = false)
      begin
        if not content.nil? and content.is_a? Numeric
          @real_class = MeasuredInteger.new(content,nil,signed)
        elsif not content.nil? and (content[0].is_a? Numeric and content[1].is_a? Numeric)
          @real_class = MeasuredInteger.new(content[0],content[1],signed)
        else
          box_size = @io.read(4).unpack("N")[0]
          case box_size
          when 1,2,4
            num = @io.read(box_size).unpack(MeasuredInteger.pack_code(box_size,signed))[0]
          when 8
            num = @io.read(box_size).unpack("NN")
            num = num[0]*65536 + num[1]
          else
            raise "I don't know how to unpack an integer #{box_size} bytes long"
          end
          @real_class = MeasuredInteger.new(num,box_size,signed)
        end
      rescue NoMethodError
        @real_class = MeasuredInteger.new(0,0,signed)
      end
    end
    
    # TODO
    def parse_version(content)
      begin
        # FIXME: Are version numbers x.y ?
        @real_class = Version.new(@io.read(@io.read(4).unpack("N")[0]).unpack("nn").join("."))
      rescue NoMethodError
        @real_class = Version.new("1.0")
      end
    end
    
    def parse_time(content)
      begin
        @real_class = Time.at(@io.read(@io.read(4).unpack("N")[0]).unpack("N")[0])
      rescue NoMethodError
        @real_class = Time.now
      end
    end
    
    def parse_signed(content)
      parse_number(content,true)
    end
  end
  
  # We may not always want to parse an entire DMAP in one go, here we extend Array so that
  # we can hold the reference to the io and the point at which the data starts, so we can parse
  # it later if the contents are requested
  class Array < Array
    attr_reader :unparsed_data
    @@parse_immediately = false
    
    def self.parse_immediately
      @@parse_immediately
    end
    
    def self.parse_immediately=(bool)
      @@parse_immediately = (bool == true)
    end
        
    alias :original_new :initialize
    def initialize(array_or_io)
      original_new
      begin
        # Lets assume its an io
        @dmap_length = array_or_io.read(4).unpack("N")[0]
        @dmap_io     = array_or_io
        @dmap_start  = @dmap_io.tell
        @unparsed_data = true
        parse_dmap if @@parse_immediately
      rescue NoMethodError
        begin
          array_or_io.each do |element|
            if element.is_dmap?
              self.push element
            else
              raise "Thisneeds to be a DMAP::Element. #{element.inspect}"
            end
          end
        rescue NoMethodError
        end
        @unparsed_data = false
      end
      
    end
    
    [:==, :===, :=~, :clone, :display, :dup, :enum_for, :eql?, :equal?, :hash, :to_a, :to_enum, :each, :length].each do |method_name|
      original = self.instance_method(method_name)
      define_method(method_name) do
        self.parse_dmap
        original.bind(self).call
      end
    end
    
    def to_dmap
      out = "\000\000\000\000"
      (0...self.length).to_a.each do |n|
        out << self[n].to_dmap
      end
      
      out[0..3] = [out.length - 4].pack("N")
      out
    end
    
    def inspect
      if not @unparsed_data
        super
      else
        "Some unparsed DMAP elements"
      end
    end
    
    # Parse any unparsed dmap data stored, and add the elements to the array
    def parse_dmap
      return if not @unparsed_data
      
      # Remember the position of the IO head so we can put it back later
      io_position = @dmap_io.tell
      
      # Go to the begining of the list
      @dmap_io.seek(@dmap_start)
      # Enumerate all tags in this list
      while @dmap_io.tell < (@dmap_start + @dmap_length)
        self.push Element.new(@dmap_io)
      end
      
      # Return the IO head to where it was
      @dmap_io.seek(io_position)
      @unparsed_data = false
    end
  end
  
  # Allows people to specify a integer and the size of the binary representation required
  #
  # If you create one with a wanted_box_size that's not 1,2,4,8 you'll run into trouble elsewhere (most likely)
  class MeasuredInteger
    attr_reader :value
    attr_accessor :box_size, :binary, :signed
    
    def initialize(value,wanted_box_size = nil,signed = false)
      @value = value
      @binary = (box_size == 1)
      self.box_size = wanted_box_size
      @signed = signed
    end
    
    # Will set the box size to the largest value of the one you specify and the maximum needed for the
    # current value.
    def box_size=(wanted_box_size)
      # Find the smallest number of bytes needed to express this number
      @box_size = [wanted_box_size || 0,(Math.log((Math.log(@value) / 2.07944154167984).ceil)/0.693147180559945).ceil].max rescue 1 # For when value = 0
    end
    
    def to_dmap
      case @box_size
      when 1,2,4,8
        [@box_size,@value].pack("N"<<MeasuredInteger.pack_code(@box_size,@signed))
      else
        raise "I don't know how to unpack an integer #{@box_size} bytes long"
      end
    end
    
    def self.pack_code(length,signed)
      out = {1=>"C",2=>"S",4=>"N",8=>"Q"}[length] # FIXME: Lower case N won't work!
      out.downcase if signed
      return out
    end
    
    def inspect
      # This is a bit of a guess, no change to the data, just helps inspection
      return (@value == 1) ? "true" : "false" if @binary
      @value
    end
  end
  
  # A class to store version numbers
  class Version
    def initialize(version = "1.0")
      @major,@minor = (version.to_s<<".0").split(".").collect{|n| n.to_i }
      if @major > 63 or @minor > 63
        raise RangeError "Neither major nor minor version numbers can be above 63. Surely that's enough?"
      end
    end
    
    def inspect
      "v#{@major}.#{@minor}"
    end
  end
  
  # For adding String#to_dmap
  class String < String
    def to_dmap
      return [self.length % 65536].pack("N") + self.to_s
    end
  end
  
  # For adding Time#to_dmap
  class Time < Time
    def to_dmap
      "\000\000\000\004"<<[self.to_i].pack("N")
    end
  end
  
  #F�CH = [:number, 'dmap.haschildcontainers']
  ABAL = [:list,   'daap.browsealbumlisting']
  ABAR = [:list,   'daap.browseartistlisting']
  ABCP = [:list,   'daap.browsecomposerlisting']
  ABGN = [:list,   'daap.browsegenrelisting']
  ABPL = [:number, 'daap.baseplaylist']
  ABRO = [:list,   'daap.databasebrowse']
  ADBS = [:list,   'daap.databasesongs']
  AEAI = [:number, 'com.apple.itunes.itms-artistid']
  AECI = [:number, 'com.apple.itunes.itms-composerid']
  AECR = [:string, 'com.apple.itunes.content-rating']
  AEEN = [:string, 'com.apple.itunes.episode-num-str']
  AEES = [:number, 'com.apple.itunes.episode-sort']
  AEFP = [:number, 'com.apple.itunes.req-fplay']
  AEGD = [:number, 'com.apple.itunes.gapless-enc-dr']
  AEGE = [:number, 'com.apple.itunes.gapless-enc-del']
  AEGH = [:number, 'com.apple.itunes.gapless-heur']
  AEGI = [:number, 'com.apple.itunes.itms-genreid']
  AEGR = [:number, 'com.apple.itunes.gapless-resy']
  AEGU = [:number, 'com.apple.itunes.gapless-dur']
  AEHD = [:number, 'com.apple.itunes.is-hd-video']
  AEHV = [:number, 'com.apple.itunes.has-video']
  AEMK = [:number, 'com.apple.itunes.mediakind']
  AENN = [:string, 'com.apple.itunes.network-name']
  AENV = [:number, 'com.apple.itunes.norm-volume']
  AEPC = [:number, 'com.apple.itunes.is-podcast']
  AEPI = [:number, 'com.apple.itunes.itms-playlistid']
  AEPP = [:number, 'com.apple.itunes.is-podcast-playlist']
  AEPS = [:number, 'com.apple.itunes.special-playlist']
  AESF = [:number, 'com.apple.itunes.itms-storefrontid']
  AESG = [:number, 'com.apple.itunes.saved-genius']
  AESI = [:number, 'com.apple.itunes.itms-songid']
  AESN = [:string, 'com.apple.itunes.series-name']
  AESP = [:number, 'com.apple.itunes.smart-playlist']
  AESU = [:number, 'com.apple.itunes.season-num']
  AESV = [:number, 'com.apple.itunes.music-sharing-version']
  AGRP = [:string, 'daap.songgrouping']
  APLY = [:list,   'daap.databaseplaylists']
  APRM = [:number, 'daap.playlistrepeatmode']
  APRO = [:version,'daap.protocolversion']
  APSM = [:number, 'daap.playlistshufflemode']
  APSO = [:list,   'daap.playlistsongs']
  ARIF = [:list,   'daap.resolveinfo']
  ARSV = [:list,   'daap.resolve']
  ASAA = [:string, 'daap.songalbumartist']
  ASAI = [:number, 'daap.songalbumid']
  ASAL = [:string, 'daap.songalbum']
  ASAR = [:string, 'daap.songartist']
  ASBK = [:number, 'daap.bookmarkable']
  ASBO = [:number, 'daap.songbookmark']
  ASBR = [:number, 'daap.songbitrate']
  ASBT = [:number, 'daap.songbeatsperminute']
  ASCD = [:number, 'daap.songcodectype']
  ASCM = [:string, 'daap.songcomment']
  ASCN = [:string, 'daap.songcontentdescription']
  ASCO = [:number, 'daap.songcompilation']
  ASCP = [:string, 'daap.songcomposer']
  ASCR = [:number, 'daap.songcontentrating']
  ASCS = [:number, 'daap.songcodecsubtype']
  ASCT = [:string, 'daap.songcategory']
  ASDA = [:time,   'daap.songdateadded']
  ASDB = [:number, 'daap.songdisabled']
  ASDC = [:number, 'daap.songdisccount']
  ASDK = [:number, 'daap.songdatakind']
  ASDM = [:time,   'daap.songdatemodified']
  ASDN = [:number, 'daap.songdiscnumber']
  ASDP = [:time,   'daap.songdatepurchased']
  ASDR = [:time,   'daap.songdatereleased']
  ASDT = [:string, 'daap.songdescription']
  ASED = [:number, 'daap.songextradata']
  ASEQ = [:string, 'daap.songeqpreset']
  ASFM = [:string, 'daap.songformat']
  ASGN = [:string, 'daap.songgenre']
  ASGP = [:number, 'daap.songgapless']
  ASHP = [:number, 'daap.songhasbeenplayed']
  ASKY = [:string, 'daap.songkeywords']
  ASLC = [:string, 'daap.songlongcontentdescription']
  ASLS = [:number, 'daap.songlongsize']
  ASPU = [:string, 'daap.songpodcasturl']
  ASRV = [:signed, 'daap.songrelativevolume']
  ASSA = [:string, 'daap.sortartist']
  ASSC = [:string, 'daap.sortcomposer']
  ASSL = [:string, 'daap.sortalbumartist']
  ASSN = [:string, 'daap.sortname']
  ASSP = [:number, 'daap.songstoptime']
  ASSR = [:number, 'daap.songsamplerate']
  ASSS = [:string, 'daap.sortseriesname']
  ASST = [:number, 'daap.songstarttime']
  ASSU = [:string, 'daap.sortalbum']
  ASSZ = [:number, 'daap.songsize']
  ASTC = [:number, 'daap.songtrackcount']
  ASTM = [:number, 'daap.songtime']
  ASTN = [:number, 'daap.songtracknumber']
  ASUL = [:string, 'daap.songdataurl']
  ASUR = [:number, 'daap.songuserrating']
  ASYR = [:number, 'daap.songyear']
  ATED = [:number, 'daap.supportsextradata']
  AVDB = [:list,   'daap.serverdatabases']
  CEJC = [:signed, 'com.apple.itunes.jukebox-client-vote']
  CEJI = [:number, 'com.apple.itunes.jukebox-current']
  CEJS = [:signed, 'com.apple.itunes.jukebox-score']
  CEJV = [:number, 'com.apple.itunes.jukebox-vote']
  MBCL = [:list,   'dmap.bag']
  MCCR = [:list,   'dmap.contentcodesresponse']
  MCNA = [:string, 'dmap.contentcodesname']
  MCNM = [:number, 'dmap.contentcodesnumber']
  MCON = [:list,   'dmap.container']
  MCTC = [:number, 'dmap.containercount']
  MCTI = [:number, 'dmap.containeritemid']
  MCTY = [:number, 'dmap.contentcodestype']
  MDCL = [:list,   'dmap.dictionary']
  MEDS = [:number, 'dmap.editcommandssupported']
  MIID = [:number, 'dmap.itemid']
  MIKD = [:number, 'dmap.itemkind']
  MIMC = [:number, 'dmap.itemcount']
  MINM = [:string, 'dmap.itemname']
  MLCL = [:list,   'dmap.listing']
  MLID = [:number, 'dmap.sessionid']
  MLOG = [:list,   'dmap.loginresponse']
  MPCO = [:number, 'dmap.parentcontainerid']
  MPER = [:number, 'dmap.persistentid']
  MPRO = [:version,'dmap.protocolversion']
  MRCO = [:number, 'dmap.returnedcount']
  MSAL = [:number, 'dmap.supportsautologout']
  MSAS = [:number, 'dmap.authenticationschemes']
  MSAU = [:number, 'dmap.authenticationmethod']
  MSBR = [:number, 'dmap.supportsbrowse']
  MSDC = [:number, 'dmap.databasescount']
  MSED = [:number, 'unknown_msed']
  MSEX = [:number, 'dmap.supportsextensions']
  MSIX = [:number, 'dmap.supportsindex']
  MSLR = [:number, 'dmap.loginrequired']
  MSMA = [:number, 'unknown_msma']
  MSML = [:list,   'unknown_msml']
  MSPI = [:number, 'dmap.supportspersistentids']
  MSQY = [:number, 'dmap.supportsquery']
  MSRS = [:number, 'dmap.supportsresolve']
  MSRV = [:list,   'dmap.serverinforesponse']
  MSTC = [:time,   'dmap.utctime']
  MSTM = [:number, 'dmap.timeoutinterval']
  MSTO = [:signed, 'dmap.utcoffset']
  MSTS = [:string, 'dmap.statusstring']
  MSTT = [:number, 'dmap.status']
  MSUP = [:number, 'dmap.supportsupdate']
  MTCO = [:number, 'dmap.specifiedtotalcount']
  MUDL = [:list,   'dmap.deletedidlisting']
  MUPD = [:list,   'dmap.updateresponse']
  MUSR = [:number, 'dmap.serverrevision']
  MUTY = [:number, 'dmap.updatetype']
  MLIT = [:list,   'dmap.listingitem']
end