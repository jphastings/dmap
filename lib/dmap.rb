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
        @tag = tag_or_dmap.read(4).downcase
        @io = tag_or_dmap if new_content.nil?
      rescue NoMethodError
        @tag = tag_or_dmap[0..3].downcase
      end
      
      # Find out the details of this tag
      begin
        @name,type = DMAP::TAGS[@tag.to_sym]
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
      begin
        "#{@tag.downcase}#{@real_class.to_dmap}"
      rescue
        warn("Error while putting #{@tag} to dmap")
        raise
      end
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
    
    def parse_byte(content)
      begin
        @real_class = MeasuredInteger.new(@io.read(@io.read(4).unpack("N")[0]).unpack("C")[0],1,false)
      rescue NoMethodError
        @real_class = MeasuredInteger.new(content || 0,1,false)
      end
    end
    
    def parse_short(content)
      begin
        @real_class = MeasuredInteger.new(@io.read(@io.read(4).unpack("N")[0]).unpack("n")[0],2,false)
      rescue NoMethodError
        @real_class = MeasuredInteger.new(content || 0,2,false)
      end
    end
    
    def parse_integer(content)
      begin
        @real_class = MeasuredInteger.new(@io.read(@io.read(4).unpack("N")[0]).unpack("N")[0],4,false) # Use L?
      rescue NoMethodError
        @real_class = MeasuredInteger.new(content || 0,4,false)
      end
    end
    
    def parse_long(content)
      begin
        @real_class = MeasuredInteger.new(@io.read(@io.read(4).unpack("N")[0]).unpack("Q")[0],8,false)
      rescue NoMethodError
        @real_class = MeasuredInteger.new(content || 0,8,false)
      end
    end
    
    def parse_signed_integer(content)
      begin
        @real_class = MeasuredInteger.new(@io.read(@io.read(4).unpack("N")[0]).unpack("l")[0],4,true)
      rescue NoMethodError
        @real_class = MeasuredInteger.new(content || 0,4,true)
      end
    end
    
    # TODO
    def parse_version(content)
      begin
        # FIXME: Are version numbers x.y ?
        @real_class = Version.new(@io.read(@io.read(4).unpack("N")[0]).unpack("CCCC").join("."))
      rescue NoMethodError
        @real_class = Version.new(content || "0.1.0.0")
      end
    end
    
    def parse_time(content)
      begin
        @real_class = Time.at(@io.read(@io.read(4).unpack("N")[0]).unpack("N")[0])
      rescue NoMethodError
        @real_class = Time.now
      end
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
      
      parse_dmap if @@parse_immediately
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
    
    def initialize(value,box_size = 1,signed = false)
      @value = value.to_i
      @box_size = box_size
      @signed = signed
    end
    
    def to_dmap # TODO: Tidy me
      case @box_size
      when 1,2,4,8
        [@box_size,@value].pack("N"<<pack_code)
      else
        raise "I don't know how to unpack an integer #{@box_size} bytes long"
      end
    end
    
    def pack_code
      {1=>"C",-1=>"c",2=>"n",4=>"N",8=>"Q",-8=>"q"}[@box_size * (@signed ? -1 : 1)] # FIXME: pack codes for all signed cases
    end
    
    def inspect
      @value
    end
  end
  
  # A class to store version numbers
  class Version
    attr_accessor :maximus,:major,:minor,:minimus
    def initialize(version = "0.1.0.0")
      @maximus,@major,@minor,@minimus = (version.to_s<<".0.0.0").split(".").collect{|n| n.to_i }
      if @maximus > 255 or @major > 255 or @minor > 255 or @minimus > 255
        raise RangeError "None of the version points can be above 255. Surely that's enough?"
      end
    end
    
    def to_dmap
      "\000\000\000\004"<<[@maximus,@major,@minor,@minimus].pack("CCCC")
    end
    
    def inspect
      "v#{@maximus}.#{@major}.#{@minor}.#{@minimus}"
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
  
  TAGS = {
    :abal => ['daap.browsealbumlisting', :list],
    :abar => ['daap.browseartistlisting', :list],
    :abcp => ['daap.browsecomposerlisting', :list],
    :abgn => ['daap.browsegenrelisting', :list],
    :abpl => ['daap.baseplaylist', :byte],
    :abro => ['daap.databasebrowse', :list],
    :adbs => ['daap.databasesongs', :list],
    :aeAI => ['com.apple.itunes.itms-artistid', :integer],
    :aeCI => ['com.apple.itunes.itms-composerid', :integer],
    :aeCR => ['com.apple.itunes.content-rating', :string],
    :aeEN => ['com.apple.itunes.episode-num-str', :string],
    :aeES => ['com.apple.itunes.episode-sort', :integer],
    :aeFP => ['com.apple.itunes.req-fplay', :byte],
    :aeGU => ['com.apple.itunes.gapless-dur', :long],
    :aeGD => ['com.apple.itunes.gapless-enc-dr', :integer],
    :aeGE => ['com.apple.itunes.gapless-enc-del', :integer],
    :aeGH => ['com.apple.itunes.gapless-heur', :integer],
    :aeGI => ['com.apple.itunes.itms-genreid', :integer],
    :aeGR => ['com.apple.itunes.gapless-resy', :long],
    :aeHD => ['com.apple.itunes.is-hd-video', :byte],
    :aeHV => ['com.apple.itunes.has-video', :byte],
    :aeMK => ['com.apple.itunes.mediakind', :byte],
    :aeNN => ['com.apple.itunes.network-name', :string],
    :aeNV => ['com.apple.itunes.norm-volume', :integer],
    :aePC => ['com.apple.itunes.is-podcast', :byte],
    :aePI => ['com.apple.itunes.itms-playlistid', :integer],
    :aePP => ['com.apple.itunes.is-podcast-playlist', :byte],
    :aePS => ['com.apple.itunes.special-playlist', :byte],
    :aeSU => ['com.apple.itunes.season-num', :integer],
    :aeSF => ['com.apple.itunes.itms-storefrontid', :integer],
    :aeSG => ['com.apple.itunes.saved-genius', :byte],
    :aeSI => ['com.apple.itunes.itms-songid', :integer],
    :aeSN => ['com.apple.itunes.series-name', :string],
    :aeSP => ['com.apple.itunes.smart-playlist', :byte],
    :aeSV => ['com.apple.itunes.music-sharing-version', :integer],
    :agrp => ['daap.songgrouping', :string],
    :aply => ['daap.databaseplaylists', :list], 
    :aprm => ['daap.playlistrepeatmode', :byte],
    :apro => ['daap.protocolversion', :version],
    :apsm => ['daap.playlistshufflemode', :byte],
    :apso => ['daap.playlistsongs', :list],
    :arif => ['daap.resolveinfo', :list],
    :arsv => ['daap.resolve', :list],
    :asaa => ['daap.songalbumartist', :string],
    :asai => ['daap.songalbumid', :long],
    :asal => ['daap.songalbum', :string],
    :asar => ['daap.songartist', :string],
    :asbk => ['daap.bookmarkable', :byte],
    :asbo => ['daap.songbookmark', :integer],
    :asbr => ['daap.songbitrate', :short],
    :asbt => ['daap.songbeatsperminute', :short],
    :ascd => ['daap.songcodectype', :integer],
    :ascm => ['daap.songcomment', :string],
    :ascn => ['daap.songcontentdescription', :string],
    :asco => ['daap.songcompilation', :byte],
    :ascp => ['daap.songcomposer', :string],
    :ascr => ['daap.songcontentrating', :byte],
    :ascs => ['daap.songcodecsubtype', :integer],
    :asct => ['daap.songcategory', :string],
    :asda => ['daap.songdateadded', :time],
    :asdb => ['daap.songdisabled', :byte],
    :asdc => ['daap.songdisccount', :short],
    :asdk => ['daap.songdatakind', :byte],
    :asdm => ['daap.songdatemodified', :time],
    :asdn => ['daap.songdiscnumber', :short],
    :asdp => ['daap.songdatepurchased', :time],
    :asdr => ['daap.songdatereleased', :time],
    :asdt => ['daap.songdescription', :string],
    :ased => ['daap.songextradata', :short],
    :aseq => ['daap.songeqpreset', :string],
    :asfm => ['daap.songformat', :string],
    :asgn => ['daap.songgenre', :string],
    :asgp => ['daap.songgapless', :byte],
    :ashp => ['daap.songhasbeenplayed', :byte],
    :asky => ['daap.songkeywords', :string],
    :aslc => ['daap.songlongcontentdescription', :string],
    :asls => ['daap.songlongsize', :long],
    :aspu => ['daap.songpodcasturl', :string],
    :asrv => ['daap.songrelativevolume', :signed_byte],
    :assu => ['daap.sortalbum', :string],
    :assa => ['daap.sortartist', :string],
    :assc => ['daap.sortcomposer', :string],
    :assl => ['daap.sortalbumartist', :string],
    :assn => ['daap.sortname', :string],
    :assp => ['daap.songstoptime', :integer],
    :assr => ['daap.songsamplerate', :integer],
    :asss => ['daap.sortseriesname', :string],
    :asst => ['daap.songstarttime', :integer],
    :assz => ['daap.songsize', :integer],
    :astc => ['daap.songtrackcount', :short],
    :astm => ['daap.songtime', :integer],
    :astn => ['daap.songtracknumber', :short],
    :asul => ['daap.songdataurl', :string],
    :asur => ['daap.songuserrating', :byte],
    :asyr => ['daap.songyear', :short],
    :ated => ['daap.supportsextradata', :short],
    :avdb => ['daap.serverdatabases', :list],
    :ceJC => ['com.apple.itunes.jukebox-client-vote', :signed_byte],
    :ceJI => ['com.apple.itunes.jukebox-current', :integer],
    :ceJS => ['com.apple.itunes.jukebox-score', :signed_short],
    :ceJV => ['com.apple.itunes.jukebox-vote', :integer],
    :"f\215ch" => ['dmap.haschildcontainers', :byte],
    :mbcl => ['dmap.bag', :list],
    :mccr => ['dmap.contentcodesresponse', :list],
    :mcna => ['dmap.contentcodesname', :string],
    :mcnm => ['dmap.contentcodesnumber', :integer],
    :mcon => ['dmap.container', :list],
    :mctc => ['dmap.containercount', :integer],
    :mcti => ['dmap.containeritemid', :integer],
    :mcty => ['dmap.contentcodestype', :short],
    :mdcl => ['dmap.dictionary', :list],
    :meds => ['dmap.editcommandssupported', :integer],
    :miid => ['dmap.itemid', :integer],
    :mikd => ['dmap.itemkind', :byte],
    :mimc => ['dmap.itemcount', :integer],
    :minm => ['dmap.itemname', :string],
    :mlcl => ['dmap.listing', :list],
    :mlid => ['dmap.sessionid', :integer],
    :mlit => ['dmap.listingitem', :list],
    :mlog => ['dmap.loginresponse', :list],
    :mpco => ['dmap.parentcontainerid', :integer],
    :mper => ['dmap.persistentid', :long],
    :mpro => ['dmap.protocolversion', :version],
    :mrco => ['dmap.returnedcount', :integer],
    :msau => ['dmap.authenticationmethod', :byte],
    :msal => ['dmap.supportsautologout', :byte],
    :msas => ['dmap.authenticationschemes', :integer],
    :msbr => ['dmap.supportsbrowse', :byte],
    :msdc => ['dmap.databasescount', :integer],
    :msed => ['unknown_msed', :byte], # TODO: Figure out what these are for
    :msex => ['dmap.supportsextensions', :byte],
    :msix => ['dmap.supportsindex', :byte],
    :mslr => ['dmap.loginrequired', :byte],
    :msma => ['unknown_msma', :long],
    :msml => ['unknown_msml', :list],
    :mspi => ['dmap.supportspersistentids', :byte],
    :msqy => ['dmap.supportsquery', :byte],
    :msrs => ['dmap.supportsresolve', :byte],
    :msrv => ['dmap.serverinforesponse', :list],
    :mstc => ['dmap.utctime', :time],
    :mstm => ['dmap.timeoutinterval', :integer],
    :msto => ['dmap.utcoffset', :signed_integer],
    :msts => ['dmap.statusstring', :string],
    :mstt => ['dmap.status', :integer],
    :msup => ['dmap.supportsupdate', :byte],
    :mtco => ['dmap.specifiedtotalcount', :integer],
    :mudl => ['dmap.deletedidlisting', :list],
    :mupd => ['dmap.updateresponse', :list],
    :musr => ['dmap.serverrevision', :integer],
    :muty => ['dmap.updatetype', :byte],
  }
end