# frozen_string_literal: true

require "test_helper"

# Regression test: rubyzip 3.x enables Zip64 for writing by default, which
# emits a Zip64 "version needed to extract" (45) plus 0xFFFFFFFF size
# placeholders and a Zip64 extra field for every entry. OOXML consumers
# (Word, Google Docs, Colore) reject docx files with Zip64 entries, so the
# output archive must be written in classic (non-Zip64) format.
class Zip64CompatibilityTest < Sablon::TestCase
  def setup
    super
    @base_path = Pathname.new(File.expand_path('../', __FILE__))
    @template_path = @base_path + 'fixtures/loops_template.docx'
    @context = {
      fruits: %w[Apple].map { |i| { name: i } },
      cars: %w[Silverado].map { |i| { name: i } }
    }
  end

  def test_generated_docx_has_no_zip64_entries
    template = Sablon.template @template_path

    Tempfile.create(['sablon_regression', '.docx']) do |tempfile|
      template.render_to_file tempfile.path, @context

      zip64_entries = zip64_entries(File.binread(tempfile.path))

      assert_empty zip64_entries,
                   "Expected no Zip64 entries, found:\n#{zip64_entries.join("\n")}"
    end
  end

  private

  ZIP64_VERSION_NEEDED = 45
  ZIP64_EXTRA_FIELD_ID = 0x0001
  LOCAL_FILE_HEADER_SIG = "PK\x03\x04".b
  UINT32_MAX = 0xFFFFFFFF

  # Walks the local file headers of a docx archive and returns the entry
  # names flagged as Zip64 (version needed 45, placeholder sizes, or a
  # Zip64 extended information extra field).
  def zip64_entries(data)
    data = data.b
    entries = []
    offset = 0

    while (header = data.index(LOCAL_FILE_HEADER_SIG, offset))
      break unless header + 30 <= data.length

      version_needed = data.byteslice(header + 4, 2).unpack1('v')
      compressed_size = data.byteslice(header + 18, 4).unpack1('V')
      uncompressed_size = data.byteslice(header + 22, 4).unpack1('V')
      name_length = data.byteslice(header + 26, 2).unpack1('v')
      extra_length = data.byteslice(header + 28, 2).unpack1('v')

      name_start = header + 30
      name = data.byteslice(name_start, name_length)
      extra = data.byteslice(name_start + name_length, extra_length) || ''.b

      if zip64?(version_needed, compressed_size, uncompressed_size, extra)
        entries << name
      end

      offset = header + 4
    end

    entries
  end

  def zip64?(version_needed, compressed_size, uncompressed_size, extra)
    return true if version_needed >= ZIP64_VERSION_NEEDED
    return true if compressed_size == UINT32_MAX || uncompressed_size == UINT32_MAX

    extra_field_ids(extra).include?(ZIP64_EXTRA_FIELD_ID)
  end

  def extra_field_ids(extra)
    ids = []
    pos = 0
    while pos + 4 <= extra.bytesize
      field_id = extra.byteslice(pos, 2).unpack1('v')
      field_size = extra.byteslice(pos + 2, 2).unpack1('v')
      ids << field_id
      pos += 4 + field_size
    end
    ids
  end
end