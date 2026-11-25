# frozen_string_literal: true

module Retcon
  # How field values are kept in history: as JSON (dates, times and decimals as strings, geometries as WKT), read back
  # through the attribute's type. Also the salted commitments that survive redaction and the row digest drift checks
  # compare.
  module Value
    module_function

    # A value as history keeps it.
    def dump(value)
      case value
      when nil, true, false, String, Integer, Float then value
      when BigDecimal then value.to_s
      when Hash then value.transform_keys(&:to_s).transform_values { |v| dump(v) }
      when Array then value.map { |v| dump(v) }
      else value.respond_to?(:as_text) ? value.as_text : value.as_json
      end
    end

    # A kept value read back for an attribute of model.
    def load(model, field, dumped) = model.type_for_attribute(field.to_s).cast(dumped)

    def same?(left, right) = canonical(left) == canonical(right)

    def canonical(value) = JSON.generate(sort(dump(value)))

    def salt = SecureRandom.hex(16)

    # The commitment to a value: SHA-256 over the salt and the value's canonical JSON. Redaction deletes value and
    # salt and keeps this, so history still verifies but short values can't be guessed from it.
    def commit(salt, value) = Digest::SHA256.hexdigest("#{salt}:#{canonical(value)}")

    # A digest of a live row's versioned fields, for drift checks: no salt, cheap to compute.
    def digest(fields) = Digest::SHA256.hexdigest(canonical(fields.sort.to_h))[0, 32]

    def sort(value)
      case value
      when Hash then value.sort.to_h { |k, v| [k, sort(v)] }
      when Array then value.map { |v| sort(v) }
      else value
      end
    end
  end
end
