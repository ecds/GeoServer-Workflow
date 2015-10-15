require 'FileUtils'
require 'yaml'
require 'net/sftp'
require 'httparty'
require 'nokogiri'
require 'optparse'
require 'ostruct'
require 'logger'
require 'highline/import'

$logger = Logger.new('map_processing.log')
$config = YAML.load_file('config.yaml')

class Map
  # A class to represent a map to load.
  include Nokogiri
  include HTTParty

  def initialize(path, metadata_file_path)
    @path = path
    @metadata_file_path = metadata_file_path
  end

  def full_path()
    # Just the full path to the file.
    @path
  end

  # TODO make this work for shape files.
  def tif_file()
    # Return the name of the Tiff file.
    @path.split('/')[-1]
  end

  # TODO make this work for shape files.
  def file_name()
    # Return just the name of the the file without the extension.
    self.tif_file.gsub('.tif', '')
  end

  # TODO this is just going to change a lot.
  def metadata_file()
    # Return the path to the metadata file.
    # TODO, make sure file exists.
    if @metadata_file_path == nil
      @path.gsub('.tif', '.xml')
    else
      @metadata_file_path
    end
  end

  def metadata()
    # Pull needed fields out of the metadata file
    begin
      data = Nokogiri::XML(File.read(self.metadata_file))
      {
        'title' => data.xpath("//field[@name='title']//value//text()"),
        'description' => data.xpath("//field[@name='description']//value//text()")
      }
    rescue
      $logger.error "Fool, no metadata for #{self.tif_file}"
      return nil
    end
  end

  def input_cs()
    if $options.use_default_cs
      $config['input_coordinate_system']
    else
      ask("Input Coordinate System?  ") { |q| q.default = $config['input_coordinate_system'] }
    end
  end

  def output_cs()
    if $options.use_default_cs
      $config['output_coordinate_system']
    else
      ask("Output Coordinate System?  ") { |q| q.default = $config['output_coordinate_system'] }
    end
  end

  def ark()
    if self.metadata != nil
      # Try to figure out if there is already an ARK in the metadata file.
      # If not, make one and add it to the metadata file.
      @data = Nokogiri::XML(File.open(self.metadata_file))
      ark_field =  @data.xpath("//field[@name='ark']//value").first
      # Check to see if the ARK filed exists or is empty.
      if ark_field.nil? || ark_field.text == ''

        ark = create_ark()

        # If there is no placeholder field, make the filed.
        if ark_field.nil?
          record = @data.xpath('//record//field')[-1]
          record.add_next_sibling("<field name='ark'><value>#{ark}</value></field>")
        # If there is one, populate it.
        else
          ark_field.content = ark
        end
        # Update the the metadata file.
        File.open(self.metadata_file, 'w') do |updated|
          updated << @data
        end
        # And return the ARK.
        return ark
      # Otherwise, just get the ARK from the metadata and return it.
      else
        ark_field.text
      end
    end
  end

  def create_ark()
    # Private method to create an ARK via the pidman REST API.
    pidman_auth = {
      username: $config['pidman_user'],
      password: $config['pidman_pass']
    }

    response = HTTParty.post \
      'https://testpid.library.emory.edu/ark/', \
      body: "domain=#{$config['pidman_domain']}&target_uri=myuri.org&name=#{self.metadata['title']}", \
      basic_auth: pidman_auth
    # The response will give us the full URL, we just want the PID.
    if  "#{response.code}" == '201'
      return response.body.split('/')[-1]
    else
      $logger.error "Failed to create ARK for #{self.file_name}. Response was #{response.code}"
    end
  end

  # Make the create_ark method private.
  private :create_ark

end

class GeoServer
  # Class to provide access to the GeoServer.
  include Nokogiri
  include HTTParty

  def initialize()
    $config = YAML.load_file('config.yaml')
  end

  # TODO make this work for shape files.
  def endpoint()
    # Return the proper endpoint to the GeoServer REST API.
    "#{$config['geoserver_url']}/geoserver/rest/workspaces/" \
    "#{$config['geoserver_workspace']}/coveragestores"
  end

  def auth()
    # Return a hash for authenticaing to the REST API.
    auth = {
      username: $config['geoserver_user'],
      password: $config['geoserver_pass']
    }
    return auth
  end

  def store_metadata(map)
    # Method to construct the body XML for adding the store.
    Nokogiri::XML::Builder.new do |xml|
      xml.coverageStore {
        xml.title map.metadata['title']
        xml.name map.ark
        xml.workspace $config['geoserver_workspace']
        xml.enabled 'true'
        xml.type 'GeoTIFF'
        xml.url "file:ATLMaps/ATL28_Sheets/#{map.tif_file}"
        xml.description map.metadata['description']
        xml.advertised 'true'
      }
    end
  end

  def layer_metadata(map)
    # Method to construct the body XML for updating the layer info.
    Nokogiri::XML::Builder.new do |xml|
        xml.coverage {
        xml.name map.ark
        xml.title map.metadata['title']
        xml.abstract map.metadata['description']
        xml.enabled 'true'
        xml.metadataLinks {
          xml.metadataLink {
            xml.type 'text/plain'
            xml.metadataType 'ISO19115:2003'
            xml.content "http://digitalscholarship.emory.edu/mslemons/1928AtlantaAtlas/#{map.file_name}.xml"
          }
        }
      }
    end
  end

  def add_store(map)
    # Method to create new store in GeoServer
    response = HTTParty.post \
      self.endpoint, \
      body: self.store_metadata(map).to_xml, \
      headers: { 'Content-type' => 'application/xml' },\
      basic_auth: self.auth

      # Log an error if store was not created.
      if  "#{response.code}" != '201'
        $logger.error "Failed to add store for #{map.file_name}. Response was #{response.code}"
        $logger.error "Error adding store #{map.file_name}: #{response.body}"
        puts "There was an error adding store for #{map.file_name}. Please see log for more details."
      end
  end

  def add_layer(map)
    # Method to take a store and make it avaliable as a layer.
    response = HTTParty.put \
      "#{self.endpoint}/#{map.ark}/external.geotiff?configure=first", \
      body: "file:data_dir/#{$config['geoserver_file_path']}/#{map.tif_file}", \
      headers: { 'Content-type' => 'text/plain' }, \
      basic_auth: self.auth

      # Log an error if store was not created.
      if  "#{response.code}" != '201'
        $logger.error "Failed to add layer for #{map.file_name}. Response was #{response.code}"
        $logger.error "Error adding layer #{map.file_name}: #{response.body}"
        puts "There was an error adding layer for #{map.file_name}. Please see log for more details."
      end
  end

  def update_layer(map)
    # Metod to set attributes to a layer.
    url = "#{self.endpoint}/#{map.ark}/coverages/#{map.file_name}.xml"

    # PUT that data!
    response = HTTParty.put \
      url, \
      body: self.layer_metadata(map).to_xml,
      headers: { 'Content-type' => 'application/xml' },\
      basic_auth: self.auth

      # Log an error if store was not created.
      if  "#{response.code}" != '200'
        $logger.error "Failed to update layer for #{map.file_name}. Response was #{response.code}"
        $logger.error "Error updateing layer for #{map.file_name}: #{response.body}"
        puts "There was an error updating layer info for #{map.file_name}. Please see log for more details."
      end
  end

end

def add_to_geoserver(map)
  # Method to add the store and corresponding layer to GeoServer.
  puts "Adding #{map.tif_file} to GeoServer as #{map.ark}."
  gs = GeoServer.new
  gs.add_store(map)
  gs.add_layer(map)
  gs.update_layer(map)
end

def upload_tiff(map)
  # Method to upload processed file to the GeoServer.
  # I snagged the progress monitor from here:
  # http://net-ssh.github.io/sftp/v2/api/classes/Net/SFTP/Operations/Upload.html
  Net::SFTP.start($config['sftp_host'], $config['sftp_user'], password: $config['sftp_pass']) do |sftp|
    sftp.upload!("#{$config['out_dir']}#{map.tif_file}", "#{$config['sftp_path']}/#{map.tif_file}") do |event, uploader, *args|
      case event
        when :open then
          puts "Starting upload of: #{map.tif_file}"
        when :put then
          percent = args[1].to_f / args[0].size.to_f * 100
          print "Uploading #{map.tif_file}: #{percent.to_i}% \r"
          $stdout.flush
        when :close then
          puts "Finished uploading #{map.tif_file}"
        when :finish then
          puts "Upload done!"
      end
    end
  end
end

def check_exit_status(status, command)
  if status != 0
    puts "Failed running:"
    puts command
    puts "Be sure you have GDAL installed on your system: See https://trac.osgeo.org/gdal/wiki/DownloadingGdalBinaries"
    exit
  end
end

def process_files(map)
  # Method to prep GeoTIFFs for use in WMS applications.
  in_dir = $config['in_dir']
  tmp_dir = $config['tmp_dir']
  out_dir = $config['out_dir']

  warp = "gdalwarp -s_srs #{map.input_cs} -t_srs #{map.output_cs} -r average\
    #{map.full_path} #{tmp_dir}#{map.tif_file}"
  system warp
  check_exit_status($?.exitstatus, warp)

  translate = "gdal_translate -co 'TILED=YES' -co 'BLOCKXSIZE=256' -co\
    'BLOCKYSIZE=256' #{tmp_dir}#{map.tif_file} #{out_dir}#{map.tif_file}"
  system translate
  check_exit_status($?.exitstatus, translate)

  addo = "gdaladdo -r average #{out_dir}#{map.tif_file} 2 4 8 16 32"
  system addo
  check_exit_status($?.exitstatus, addo)

  # Clean up tmp files.
  FileUtils.rm("#{tmp_dir}#{map.tif_file}")

end

def run_all(map)
  if map.metadata != nil
    process_files(map)
    upload_tiff(map)
    add_to_geoserver(map)
  else
    $logger.error "Could not process #{map.tif_file}. No metadata file found."
  end
end

$options = OpenStruct.new
OptionParser.new do |opt|
  opt.on('--tif', '-t /path/to/map.tif', ' Path to tif file.') {
    |o| $options.tif_file_path = o
  }
  opt.on('--mdfile', '-d /path/to/metadata.xml', 'Path to metadata file.') {
    |o| $options.metadata_file_path = o
  }
  opt.on('--method', '-m METHOD', 'Run a single method.') {
    |o| $options.method_to_run = o
  }
  opt.on('--default_cs', '-y', 'Use the coordinate systems form config file.') {
    |o| $options.use_default_cs = o
  }
end.parse!

def run_what(map)
  if $options.method_to_run != nil
    action = $options.method_to_run
    if action == 'process'
      process_files(map)
    elsif action == 'upload'
      upload_tiff(map)
    elsif action == 'add_to_geoserver'
      add_to_geoserver(map)
    else
      puts "Unkonw method."
      exit
    end
  else
    run_all(map)
  end
end

if $options.tif_file_path
  map = Map.new($options.tif_file_path, $options.metadata_file_path)
else
  maps = []
  Dir[$config['in_dir']].each do |file|
    map = Map.new(file, nil)
    maps.push(map)
  end
end

if maps == nil
  run_what(map)
else
  if $options.metadata_file_path != nil
    puts "You cannot specify a metadata file when processing multiple files."
    exit
  end
  maps.each do |map|
    run_what(map)
  end
end
