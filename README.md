# GeoServer Workflow
This script automates the process for preparing GeoTIFFs for use in WMS applications and adding them to GeoServer.

This script is specific to Emory University's workflow and infrastructure, but could be adapted. Please feel free to open an issue here or contact <libsysdev-l@listserv.cc.emory.edu> if you have questions.

Special thanks to Eric Willoughby at Georgia State University for working out the GDAL commands and consulting on GeoServer REST calls.

## Dependencies
You will need ruby and a few gems:

<code>gem install net-sftp</code>

<code>gem install httparty</code>

<code>gem install nokogiri</code>

## config.yaml
Provided is a sample config file (<code>config.yaml.dst</code>). Rename that to <code>config.yaml</code> and fill in the various items.

## What the script does
* Collects all the tiff files in the configured directory
* Runs each tiff though the following process one at a time
	* Uses GDAL commands to prepare for WMS applications
	* Finds the proper metadata file based on configured directory and matching file name. For example, if the script finds Sheet4.tif, it will look for Sheet4.xml
	* Checks the metadata file for an ARK. If no ARK is found, it creates one and adds it to the metadata file
	* Uploads the GeoTIFF to the configured remote directory
	* Adds a store in GeoServer for the GeoTIFF using the ARK as the `Name` and the title from the metadata file for the `Title`
	* Adds a layer in GeoServer for the new store
	* Edits/updates the layer's fields in GeoServer based on the metadata

## Usage
If you do not pass any options to the script, it will run though the process described above. You can pass it a specific path to a GeoTIFF. You can also pass it a specific path for a metadata file. If you do not provide a metadata file, the script will try to find it based on the file's name. Note: You can only specify a metadata file when specifying a GeoTIFF.

You can also run a single part of the script:

	ruby tada [options]
		-t, --tif /path/to/map.tif         Path to tif file.
    	-d, --mdfile /path/to/metadata.xml Path to metadata file.
      	-m, --method METHOD                Run a single method.
       Methods:
       	process # Runs the GeoTIFF thorugh GDAL process
       	upload # Uploads GeoTIFF to GeoServer
       	add_store # Adds a store in GeoServer for the GeoTIFF
       	add_layer # Creates a layer from GeoTIFF's store in GeoServer
       	update_layer # Updates the layer's metadata in GeoServer

## License
This GeoServer-Workflow is distributed under the [Apache 2.0 License](http://www.apache.org/licenses/LICENSE-2.0). Enjoy.
