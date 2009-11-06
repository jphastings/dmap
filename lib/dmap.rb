require 'forwardable'
require 'stringio'
require 'delegate'

# If you plan on extending this module (like you'll need to if you want extra tags available)
# make sure you don't use any class names with four letters in. It saves a bit of processor time
# if I don't have to remove
module DMAP
  # Represents any DMAP tag and its content.
  # Will have methods appropriate to the dmap specified
  class Element
    attr_reader :unparsed_content
    attr_reader :name
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
        @unparsed_content = true
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
        @real_class = Version.new(@io.read(@io.read(4).unpack("N")[0])) # FIXME: Should be Q?
      rescue NoMethodError
        @real_class = Version.new(0)
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
    attr_accessor :parse_immediately
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
        @dmap_length = array_or_io.read(4).unpack("N")[0] # FIXME: Should be Q? but that's not working?
        @dmap_io     = array_or_io
        @dmap_start  = @dmap_io.tell
        @unparsed_data = true
        parse_dmap if @@parse_immediately
      rescue NoMethodError
        begin
          array_or_io.each do |element|
            self.push element
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
      @box_size = [wanted_box_size || 0,(Math.log(@value) / 2.07944154167984).ceil].max rescue 0 # For when value = 0
    end
    
    def to_dmap
      case @box_size
      when 1,2,4
        [@box_size,@value].pack("N"<<MeasuredInteger.pack_code(@box_size,@signed))
      when 8
        [@box_size,@value / 65536,@value % 65536].pack((@signed) ? "Nll" : "NNN") # FIXME: How do you do signed version :S
      else
        raise "I don't know how to unpack an integer #{@box_size} bytes long"
      end
    end
    
    def self.pack_code(length,signed)
      out = {1=>"C",2=>"S",4=>"N"}[length]
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
    # TODO
    def initialize(version)
      
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
      [self.to_i / 65536,self.to_i % 65536].pack("NN")
    end
  end
  
  MLIT = [:list,   'dmap.listingitem']
  ASSL = [:string, 'daap.sortalbumartist']
  ASBO = [:number, 'daap.songbookmark']
  AEGU = [:number, 'com.apple.itunes.gapless-dur']
  MSRV = [:list,   'dmap.serverinforesponse']
  AESN = [:string, 'com.apple.itunes.series-name']
  ASDR = [:time,   'daap.songdatereleased']
  MPER = [:number, 'dmap.persistentid']
  ASSR = [:number, 'daap.songsamplerate']
  ASBT = [:number, 'daap.songbeatsperminute']
  AEGE = [:number, 'com.apple.itunes.gapless-enc-del']
  MSTO = [:signed, 'dmap.utcoffset']
  ABAR = [:list,   'daap.browseartistlisting']
  MCNA = [:string, 'dmap.contentcodesname']
  ASEQ = [:string, 'daap.songeqpreset']
  AGRP = [:string, 'daap.songgrouping']
  MSAU = [:number, 'dmap.authenticationmethod']
  ASCN = [:string, 'daap.songcontentdescription']
  AEGR = [:number, 'com.apple.itunes.gapless-resy']
  ASSZ = [:number, 'daap.songsize']
  MSTT = [:number, 'dmap.status']
  MCTC = [:number, 'dmap.containercount']
  ASGP = [:number, 'daap.songgapless']
  APRO = [:version,'daap.protocolversion']
  ABPL = [:number, 'daap.baseplaylist']
  MSBR = [:number, 'dmap.supportsbrowse']
  ASTN = [:number, 'daap.songtracknumber']
  ASCR = [:number, 'daap.songcontentrating']
  AEMK = [:number, 'com.apple.itunes.mediakind']
  MUDL = [:list,   'dmap.deletedidlisting']
  APSO = [:list,   'daap.playlistsongs']
  ADBS = [:list,   'daap.databasesongs']
  MDCL = [:list,   'dmap.dictionary']
  ASLC = [:string, 'daap.songlongcontentdescription']
  MSEX = [:number, 'dmap.supportsextensions']
  ASYR = [:number, 'daap.songyear']
  ASDA = [:time,   'daap.songdateadded']
  AEPC = [:number, 'com.apple.itunes.is-podcast']
  MUTY = [:number, 'dmap.updatetype']
  MIKD = [:number, 'dmap.itemkind']
  ASRV = [:signed, 'daap.songrelativevolume']
  ASAA = [:string, 'daap.songalbumartist']
  AECI = [:number, 'com.apple.itunes.itms-composerid']
  MSMA = [:number, 'unknown_msma']
  AEPS = [:number, 'com.apple.itunes.special-playlist']
  CEJC = [:signed, 'com.apple.itunes.jukebox-client-vote']
  ASDC = [:number, 'daap.songdisccount']
  MLCL = [:list,   'dmap.listing']
  ASSA = [:string, 'daap.sortartist']
  ASAR = [:string, 'daap.songartist']
  AEES = [:number, 'com.apple.itunes.episode-sort']
  MSQY = [:number, 'dmap.supportsquery']
  ASDN = [:number, 'daap.songdiscnumber']
  AESG = [:number, 'com.apple.itunes.saved-genius']
  MLOG = [:list,   'dmap.loginresponse']
  ASSN = [:string, 'daap.sortname']
  ASBR = [:number, 'daap.songbitrate']
  MSTC = [:time,   'dmap.utctime']
  ASDT = [:string, 'daap.songdescription']
  AESP = [:number, 'com.apple.itunes.smart-playlist']
  ABAL = [:list,   'daap.browsealbumlisting']
  MBCL = [:list,   'dmap.bag']
  MPRO = [:version,'dmap.protocolversion']
  ASSS = [:string, 'daap.sortseriesname']
  ASCD = [:number, 'daap.songcodectype']
  AEGH = [:number, 'com.apple.itunes.gapless-heur']
  APLY = [:list,   'daap.databaseplaylists']
  ABCP = [:list,   'daap.browsecomposerlisting']
  MCNM = [:number, 'dmap.contentcodesnumber']
  ASFM = [:string, 'daap.songformat']
  MSAL = [:number, 'dmap.supportsautologout']
  ASTC = [:number, 'daap.songtrackcount']
  ASCO = [:number, 'daap.songcompilation']
  AEHD = [:number, 'com.apple.itunes.is-hd-video']
  MSUP = [:number, 'dmap.supportsupdate']
  MCTI = [:number, 'dmap.containeritemid']
  ASHP = [:number, 'daap.songhasbeenplayed']
  MSDC = [:number, 'dmap.databasescount']
  AENN = [:string, 'com.apple.itunes.network-name']
  ASUL = [:string, 'daap.songdataurl']
  ASCS = [:number, 'daap.songcodecsubtype']
  MUPD = [:list,   'dmap.updateresponse']
  ASLS = [:number, 'daap.songlongsize']
  ARIF = [:list,   'daap.resolveinfo']
  AEAI = [:number, 'com.apple.itunes.itms-artistid']
  MEDS = [:number, 'dmap.editcommandssupported']
  F�CH = [:number, 'dmap.haschildcontainers']
  MSIX = [:number, 'dmap.supportsindex']
  ATED = [:number, 'daap.supportsextradata']
  AEPI = [:number, 'com.apple.itunes.itms-playlistid']
  MIMC = [:number, 'dmap.itemcount']
  AECR = [:string, 'com.apple.itunes.content-rating']
  ASAI = [:number, 'daap.songalbumid']
  MSML = [:list,   'unknown_msml']
  ASDK = [:number, 'daap.songdatakind']
  AESU = [:number, 'com.apple.itunes.season-num']
  CEJI = [:number, 'com.apple.itunes.jukebox-current']
  MLID = [:number, 'dmap.sessionid']
  ASSC = [:string, 'daap.sortcomposer']
  ASBK = [:number, 'daap.bookmarkable']
  AEFP = [:number, 'com.apple.itunes.req-fplay']
  MSRS = [:number, 'dmap.supportsresolve']
  CEJV = [:number, 'com.apple.itunes.jukebox-vote']
  ASDP = [:time,   'daap.songdatepurchased']
  AESI = [:number, 'com.apple.itunes.itms-songid']
  MPCO = [:number, 'dmap.parentcontainerid']
  AEGD = [:number, 'com.apple.itunes.gapless-enc-dr']
  ASSP = [:number, 'daap.songstoptime']
  MSTM = [:number, 'dmap.timeoutinterval']
  MCCR = [:list,   'dmap.contentcodesresponse']
  ASED = [:number, 'daap.songextradata']
  AESV = [:number, 'com.apple.itunes.music-sharing-version']
  MRCO = [:number, 'dmap.returnedcount']
  AEGI = [:number, 'com.apple.itunes.itms-genreid']
  ASST = [:number, 'daap.songstarttime']
  ASCM = [:string, 'daap.songcomment']
  MSTS = [:string, 'dmap.statusstring']
  ASGN = [:string, 'daap.songgenre']
  APRM = [:number, 'daap.playlistrepeatmode']
  ABGN = [:list,   'daap.browsegenrelisting']
  MCON = [:list,   'dmap.container']
  MSAS = [:number, 'dmap.authenticationschemes']
  ASTM = [:number, 'daap.songtime']
  ASCP = [:string, 'daap.songcomposer']
  AEHV = [:number, 'com.apple.itunes.has-video']
  MTCO = [:number, 'dmap.specifiedtotalcount']
  ABRO = [:list,   'daap.databasebrowse']
  MCTY = [:number, 'dmap.contentcodestype']
  ASKY = [:string, 'daap.songkeywords']
  APSM = [:number, 'daap.playlistshufflemode']
  MSED = [:number, 'unknown_msed']
  ASCT = [:string, 'daap.songcategory']
  AENV = [:number, 'com.apple.itunes.norm-volume']
  ASUR = [:number, 'daap.songuserrating']
  MUSR = [:number, 'dmap.serverrevision']
  MIID = [:number, 'dmap.itemid']
  ASPU = [:string, 'daap.songpodcasturl']
  ARSV = [:list,   'daap.resolve']
  MSLR = [:number, 'dmap.loginrequired']
  AVDB = [:list,   'daap.serverdatabases']
  ASDB = [:number, 'daap.songdisabled']
  AEPP = [:number, 'com.apple.itunes.is-podcast-playlist']
  MINM = [:string, 'dmap.itemname']
  ASAL = [:string, 'daap.songalbum']
  AEEN = [:string, 'com.apple.itunes.episode-num-str']
  ASSU = [:string, 'daap.sortalbum']
  MSPI = [:number, 'dmap.supportspersistentids']
  CEJS = [:signed, 'com.apple.itunes.jukebox-score']
  ASDM = [:time,   'daap.songdatemodified']
  AESF = [:number, 'com.apple.itunes.itms-storefrontid']
end

p a = DMAP::Element.new("msrv",[
  DMAP::Element.new('mspi',[400,4]),
  DMAP::Element.new("minm","Howdy Ho!"),
  DMAP::Element.new("mstc")
])
open("test","w") do |f|
  f.write a.to_dmap
end

p a.to_dmap
a.close_stream

DMAP::Array.parse_immediately = true
p DMAP::Element.new(open("test"))