require 'FileUtils'
require 'yaml'
require 'net/sftp'
require 'httparty'
require 'nokogiri'

@config = YAML.load_file('config.yaml')

class Map
  include Nokogiri
  include HTTParty

  def initialize(path)
    @path = path
    @config = YAML.load_file('config.yaml')
  end

  def full_path()
    @path
  end

  def tif_file()
    @path.split('/')[-1]
  end

  def file_name()
    self.tif_file.gsub('.tif', '')
  end

  def metadata_file()
    @path.gsub('.tif', '.xml')
  end

  def metadata()
    data = Nokogiri::XML(File.read(self.metadata_file))
    {
      'title' => data.xpath("//field[@name='title']//value//text()"),
      'description' => data.xpath("//field[@name='description']//value//text()")
    }
  end

  def ark()
    @data = Nokogiri::XML(File.open(self.metadata_file))
    ark_field =  @data.xpath("//field[@name='ark']//value").first
    if ark_field.nil? || ark_field.text == ''

      ark = create_ark()

      if ark_field.nil?
        record = @data.xpath('//record//field')[-1]
        record.add_next_sibling("<field name='ark'><value>#{ark}</value></field>")
      else
        ark_field.content = ark
      end

      File.open(self.metadata_file, 'w') do |updated|
        updated << @data
      end

      return ark
    else
      ark_field.text
    end
  end

  def create_ark()
    pidman_auth = {
      username: @config['pidman_user'],
      password: @config['pidman_pass']
    }
    response = HTTParty.post \
      'https://testpid.library.emory.edu/ark/', \
      body: "domain=#{@config['pidman_domain']}&target_uri=myuri.org&name=#{self.metadata['title']}", \
      basic_auth: pidman_auth

    response.body.split('/')[-1]
  end

  private :create_ark

end

class GeoServer
  def initialize()
    @config = YAML.load_file('config.yaml')
  end

  def endpoint()
    "#{@config['geoserver_url']}/geoserver/rest/workspaces/" \
    "#{@config['geoserver_workspace']}/coveragestores"
  end

  def auth()
    auth = {
      username: @config['geoserver_user'],
      password: @config['geoserver_pass']
    }
    return auth
  end
end

def add_store(map, ark)
  gs = GeoServer.new
  data = Nokogiri::XML::Builder.new do |xml|
    xml.coverageStore {
      xml.title map.metadata['title']
      xml.name ark
      xml.workspace @config['geoserver_workspace']
      xml.enabled 'true'
      xml.type 'GeoTIFF'
      xml.url "file:ATLMaps/ATL28_Sheets/#{map.tif_file}"
      xml.description map.metadata['description']
      xml.advertised 'true'
    }
  end

  response = HTTParty.post \
    gs.endpoint, \
    body: data.to_xml, \
    headers: { 'Content-type' => 'application/xml' },\
    basic_auth: gs.auth

  puts response.code
end

def update_layer(map, ark)
  data = Nokogiri::XML::Builder.new do |xml|
    xml.coverage {
      xml.name ark
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

  response = HTTParty.put \
    url, \
    body: data.to_xml,
    headers: { 'Content-type' => 'application/xml' },\
    basic_auth: gs.auth

  puts response.code
end

def add_layer(map, ark)
  gs = GeoServer.new
  response = HTTParty.put \
    "#{gs.endpoint}/#{ark}/external.geotiff?configure=first", \
    body: "file:data_dir/#{@config['geoserver_file_path']}/#{map.tif_file}", \
    headers: { 'Content-type' => 'text/plain' }, \
    basic_auth: gs.auth

  puts response.code
end

def upload_tiff(map)
  Net::SFTP.start(@config['sftp_host'], @config['sftp_user'], password: @config['sftp_pass']) do |sftp|
    sftp.upload!("#{@config['out_dir']}#{map.tif_file}", "#{@config['sftp_path']}/#{map.tif_file}")
  end
end

def process_files(map)
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

  FileUtils.rm("#{tmp_dir}#{map.tif_file}")

end

Dir[@config['in_dir']].each do |file|
  map = Map.new(file)
  #process_files(map)
  # upload_tiff(map)
  # ark = create_ark(map)
  ark = map.ark
  puts map.tif_file
  puts ark
  #add_store(map, ark)
  #add_layer(map, ark)
  #update_layer(map, ark)
end
