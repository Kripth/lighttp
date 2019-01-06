module lighttp.server.resource;

import std.array : Appender;
import std.base64 : Base64URLNoPadding;
import std.digest.crc : crc32Of;
import std.string : indexOf, strip;
import std.zlib : HeaderFormat, Compress;

import lighttp.util : StatusCodes, Http;

class Resource {
	
	private immutable string mime;
	
	public immutable size_t thresold;
	
	public const(void)[] uncompressed;
	public const(void)[] compressed = null;
	
	public this(string mime, size_t thresold=512) {
		this.mime = mime;
		this.thresold = thresold;
	}
	
	public this(string mime, in void[] data) {
		this(mime);
		this.data = data;
	}
	
	public @property const(void)[] data(in void[] data) {
		this.uncompressed = data;
		if(data.length >= this.thresold) this.compress();
		else this.compressed = null;
		return this.uncompressed;
	}
	
	private void compress() {
		Compress compress = new Compress(6, HeaderFormat.gzip);
		auto data = compress.compress(this.uncompressed);
		data ~= compress.flush();
		this.compressed = data;
	}
	
	public void apply(Http req, Http res) {
		if(this.compressed !is null && req.headers.get("accept-encoding", "").indexOf("gzip") != -1) {
			res.headers["Content-Encoding"] = "gzip";
			res.body_ = cast(string)this.compressed;
		} else {
			res.body_ = cast(string)this.uncompressed;
		}
		res.contentType = this.mime;
	}
	
}

class CachedResource : Resource {
	
	private string etag;
	
	public this(string mime, size_t thresold=512) {
		super(mime, thresold);
	}
	
	public this(string mime, in void[] data) {
		super(mime, data);
	}
	
	public override @property const(void)[] data(in void[] data) {
		this.etag = Base64URLNoPadding.encode(crc32Of(data));
		return super.data(data);
	}
	
	public override void apply(Http req, Http res) {
		if(req.headers.get("if-none-match", "") == this.etag) {
			res.status = StatusCodes.notModified;
		} else {
			super.apply(req, res);
			res.headers["Cache-Control"] = "public, max-age=31536000";
			res.headers["ETag"] = this.etag;
		}
	}
	
}

class TemplatedResource : Resource {

	private abstract class Data {

		abstract string translate(string[string]);

	}

	private class StringData : Data {

		string data;

		this(string data) {
			this.data = data;
		}

		override string translate(string[string] dictionary) {
			return data;
		}

	}

	private class TranslateData : Data {

		string key;

		this(string key) {
			this.key = key;
		}

		override string translate(string[string] dictionary) {
			auto ptr = key in dictionary;
			return ptr ? *ptr : "";
		}

	}
	
	private Data[] tdata;
	
	public this(string mime, size_t thresold=512) {
		super(mime, thresold);
	}
	
	public this(string mime, in void[] _data) {
		this(mime);
		string data = cast(string)_data;
		while(data.length) {
			immutable start = data.indexOf("{{");
			if(start != -1) {
				this.tdata ~= new StringData(data[0..start]);
				data = data[start+2..$];
				immutable end = data.indexOf("}}");
				if(end != -1) {
					this.tdata ~= new TranslateData(data[0..end].strip);
					data = data[end+2..$];
				}
			} else {
				this.tdata ~= new StringData(data);
				break;
			}
		}
	}
	
	public Resource apply(string[string] dictionary) {
		Appender!string appender;
		foreach(data ; this.tdata) {
			appender.put(data.translate(dictionary));
		}
		this.data = appender.data;
		return this;
	}
	
}
