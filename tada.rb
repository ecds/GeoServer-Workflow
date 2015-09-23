require 'FileUtils'
require 'yaml'
require 'net/sftp'
require 'httparty'
require 'nokogiri'
require 'optparse'
require 'ostruct'

@config = YAML.load_file('config.yaml')

class Map
  # A class to represent a map to load.
  include Nokogiri
  include HTTParty

  def initialize(path, metadata_file_path)
    @path = path
    @metadata_file_path = metadata_file_path
    @config = YAML.load_file('config.yaml')
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
    if @metadata_file_path == nil
      @path.gsub('.tif', '.xml')
    else
      @metadata_file_path
    end
  end

  def metadata()
    # Pull needed fields out of the metadata file
    data = Nokogiri::XML(File.read(self.metadata_file))
    {
      'title' => data.xpath("//field[@name='title']//value//text()"),
      'description' => data.xpath("//field[@name='description']//value//text()")
    }
  end

  def ark()
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

  def create_ark()
    # Private method to create an ARK via the pidman REST API.
    pidman_auth = {
      username: @config['pidman_user'],
      password: @config['pidman_pass']
    }
    response = HTTParty.post \
      'https://testpid.library.emory.edu/ark/', \
      body: "domain=#{@config['pidman_domain']}&target_uri=myuri.org&name=#{self.metadata['title']}", \
      basic_auth: pidman_auth
    # The response will give us the full URL, we just want the PID.
    response.body.split('/')[-1]
  end

  # Make the create_ark method private.
  private :create_ark

end

class GeoServer
  # Class to provide access to the GeoServer.
  def initialize()
    @config = YAML.load_file('config.yaml')
  end

  # TODO make this work for shape files.
  def endpoint()
    # Return the proper endpoint to the GeoServer REST API.
    "#{@config['geoserver_url']}/geoserver/rest/workspaces/" \
    "#{@config['geoserver_workspace']}/coveragestores"
  end

  def auth()
    # Return a hash for authenticaing to the REST API.
    auth = {
      username: @config['geoserver_user'],
      password: @config['geoserver_pass']
    }
    return auth
  end
end

def add_store(map)
  # Method to add the store to GeoServer.
  gs = GeoServer.new
  # Generate the XML to set the attributes for the store.
  data = Nokogiri::XML::Builder.new do |xml|
    xml.coverageStore {
      xml.title map.metadata['title']
      xml.name map.ark
      xml.workspace @config['geoserver_workspace']
      xml.enabled 'true'
      xml.type 'GeoTIFF'
      xml.url "file:ATLMaps/ATL28_Sheets/#{map.tif_file}"
      xml.description map.metadata['description']
      xml.advertised 'true'
    }
  end

  # Post that to the REST API.
  response = HTTParty.post \
    gs.endpoint, \
    body: data.to_xml, \
    headers: { 'Content-type' => 'application/xml' },\
    basic_auth: gs.auth

  # TODO add error handeling to the respons.
  puts response.code
end

def update_layer(map)
  # Metod to set attributes to a layer.
  data = Nokogiri::XML::Builder.new do |xml|
    # Generate the XML for the post body.
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
  gs = GeoServer.new
  url = "#{gs.endpoint}/#{ark}/coverages/#{map.file_name}.xml"

  # PUT that data!
  response = HTTParty.put \
    url, \
    body: data.to_xml,
    headers: { 'Content-type' => 'application/xml' },\
    basic_auth: gs.auth

  # TODO add some error handeling to the response code.
  puts response.code
end

def add_layer(map)
  # Method to take a store and make it avaliable as a layer.
  gs = GeoServer.new
  response = HTTParty.put \
    "#{gs.endpoint}/#{map.ark}/external.geotiff?configure=first", \
    body: "file:data_dir/#{@config['geoserver_file_path']}/#{map.tif_file}", \
    headers: { 'Content-type' => 'text/plain' }, \
    basic_auth: gs.auth

  puts response.code
end

def upload_tiff(map)
  # Method to upload processed file to the GeoServer.
  Net::SFTP.start(@config['sftp_host'], @config['sftp_user'], password: @config['sftp_pass']) do |sftp|
    sftp.upload!("#{@config['out_dir']}#{map.tif_file}", "#{@config['sftp_path']}/#{map.tif_file}")
  end
end

def process_files(map)
  # Method to prep GeoTIFFs for use in WMS applications.
  in_dir = @config['in_dir']
  tmp_dir = @config['tmp_dir']
  out_dir = @config['out_dir']

  warp = "gdalwarp -s_srs EPSG:2240 -t_srs EPSG:4326 -r average\
    #{map.full_path} #{tmp_dir}#{map.tif_file}"
  system warp

  translate = "gdal_translate -co 'TILED=YES' -co 'BLOCKXSIZE=256' -co\
    'BLOCKYSIZE=256' #{tmp_dir}#{map.tif_file} #{out_dir}#{map.tif_file}"
  system translate

  addo = "gdaladdo -r average #{out_dir}#{map.tif_file} 2 4 8 16 32"
  system addo

  # Clean up tmp files.
  FileUtils.rm("#{tmp_dir}#{map.tif_file}")

end

def run_all(map)
  process_files(map)
  upload_tiff(map)
  add_store(map)
  add_layer(map)
  update_layer(map)
end

@options = OpenStruct.new
OptionParser.new do |opt|
  opt.on('--tif', '-t /path/to/map.tif', ' Path to tif file.') {
    |o| @options.tif_file_path = o
  }
  opt.on('--mdfile', '-md /path/to/metadata.xml', 'Path to metadata file.') {
    |o| @options.metadata_file_path = o
  }
  opt.on('--method', '-m METHOD', 'Run a single method.') {
    |o| @options.method_to_run = o
  }
end.parse!

def run_what(map)
  if @options.method_to_run != nil
    action = @options.method_to_run
    if action == 'porcess'
      porcess_files(map)
    elsif action == 'upload'
      upload_tiff(map)
    elsif action == 'add_store'
      add_store(map)
    elsif action == 'add_layer'
      add_layer(map)
    elsif action == 'update_layer'
      update_layer(map)
    else
      puts "Unkonw method."
      exit
    end
  else
    run_all(map)
  end
end

if @options.tif_file_path
  map = Map.new(@options.tif_file_path, @options.metadata_file_path)
else
  maps = []
  Dir[@config['in_dir']].each do |file|
    map = Map.new(file, nil)
    maps.push(map)
  end
end

if maps == nil
  run_what(map)
else
  if @options.metadata_file_path != nil
    puts "You can not specify a metadata file when processing multiple files."
    exit
  end
  maps.each do |map|
    run_what(map)
  end
end
