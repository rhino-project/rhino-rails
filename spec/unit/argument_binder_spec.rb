# frozen_string_literal: true

require "spec_helper"

# The binder is shared by named scopes and computed attributes. These specs pin
# BOTH subjects: the algorithm must behave identically, and each feature must
# keep its own error wording and its own exception class.
RSpec.describe Rhino::ArgumentBinder do
  def spec(params, optional = [])
    { params: params.map(&:to_s), optional: optional.map(&:to_s) }
  end

  def bind_computed(name, spec, raw)
    Rhino::ComputedAttributeSpec.bind(name, spec, raw)
  end

  describe "happy paths" do
    it "binds no arguments for a blank raw value" do
      expect(bind_computed("headcount", spec([]), "")).to eq([])
      expect(bind_computed("headcount", spec([]), nil)).to eq([])
    end

    it "binds a bare value to the single declared parameter" do
      expect(bind_computed("since", spec(%w[from]), "2026-01-01")).to eq(["2026-01-01"])
    end

    it "binds named arguments in declared order, not the order they arrived" do
      expect(bind_computed("revenue", spec(%w[from to]), { "to" => "b", "from" => "a" })).to eq(%w[a b])
    end

    it "drops a trailing omitted optional so the callable default applies" do
      expect(bind_computed("revenue", spec(%w[from to], %w[to]), { "from" => "a" })).to eq(["a"])
    end

    it "drops EVERY trailing nil when all parameters are optional and omitted" do
      # Array#any? is false for [nil], which is why the drop loop tests
      # emptiness explicitly. Getting this wrong hands the callable an explicit
      # nil instead of letting its own default apply.
      expect(bind_computed("tone", spec(%w[tone], %w[tone]), "")).to eq([])
      expect(bind_computed("pair", spec(%w[a b], %w[a b]), "")).to eq([])
    end

    it "passes an omitted middle optional as nil" do
      expect(
        bind_computed("window", spec(%w[from mid to], %w[mid]), { "from" => "a", "to" => "c" })
      ).to eq(["a", nil, "c"])
    end

    it "coerces 'true' and 'false' to real booleans, case-insensitively" do
      expect(bind_computed("flagged", spec(%w[on]), "true")).to eq([true])
      expect(bind_computed("flagged", spec(%w[on]), "FALSE")).to eq([false])
      expect(bind_computed("flagged", spec(%w[on]), "yes")).to eq(["yes"])
    end

    it "never coerces parameter names" do
      expect(bind_computed("weird", spec(%w[true]), { "true" => "x" })).to eq(["x"])
    end

    it "leaves non-strings alone when coercing" do
      expect(described_class.coerce(3)).to eq(3)
      expect(described_class.coerce(nil)).to be_nil
    end

    it "matches computed-attribute parameter names verbatim, without underscoring" do
      # Laravel and NestJS match parameter names exactly; computed attributes do
      # the same. (Named scopes deliberately underscore theirs — see below.)
      expect { bind_computed("revenue", spec(%w[from_date]), { "fromDate" => "x" }) }
        .to raise_error(
          Rhino::InvalidComputedAttributeArgumentsError,
          "Computed attribute 'revenue' does not accept parameter 'fromDate'"
        )
    end
  end

  describe "the four argument errors under the Computed attribute subject" do
    it "names a missing required parameter" do
      expect { bind_computed("revenue", spec(%w[from to]), { "from" => "a" }) }
        .to raise_error(
          Rhino::InvalidComputedAttributeArgumentsError,
          "Computed attribute 'revenue' requires parameter 'to'"
        )
    end

    it "names an unknown parameter" do
      expect { bind_computed("revenue", spec(%w[from to]), { "from" => "a", "to" => "b", "nope" => "x" }) }
        .to raise_error(
          Rhino::InvalidComputedAttributeArgumentsError,
          "Computed attribute 'revenue' does not accept parameter 'nope'"
        )
    end

    it "refuses a bare value for a multi-parameter attribute" do
      expect { bind_computed("revenue", spec(%w[from to]), "2026-01-01") }
        .to raise_error(
          Rhino::InvalidComputedAttributeArgumentsError,
          "Computed attribute 'revenue' requires named parameters"
        )
    end

    it "refuses a positional argument list" do
      expect { bind_computed("revenue", spec(%w[from to]), %w[a b]) }
        .to raise_error(
          Rhino::InvalidComputedAttributeArgumentsError,
          "Computed attribute 'revenue' requires named parameters"
        )
    end

    it "refuses a non-scalar argument value" do
      expect { bind_computed("revenue", spec(%w[from to]), { "from" => { "deep" => 1 }, "to" => "b" }) }
        .to raise_error(
          Rhino::InvalidComputedAttributeArgumentsError,
          "Computed attribute 'revenue' requires named parameters"
        )
    end

    it "refuses any argument sent to a parameterless attribute" do
      expect { bind_computed("headcount", spec([]), "5") }
        .to raise_error(
          Rhino::InvalidComputedAttributeArgumentsError,
          "Computed attribute 'headcount' does not accept arguments"
        )

      expect { bind_computed("headcount", spec([]), { "from" => "a" }) }
        .to raise_error(
          Rhino::InvalidComputedAttributeArgumentsError,
          "Computed attribute 'headcount' does not accept arguments"
        )
    end
  end

  describe "the scope subject is unchanged by the extraction" do
    it "still says Scope in every message" do
      cases = [
        [spec(%w[from to]), { "from" => "a" }, "Scope 'window' requires parameter 'to'"],
        [spec(%w[from]), { "nope" => "a" }, "Scope 'window' does not accept parameter 'nope'"],
        [spec(%w[from to]), "a", "Scope 'window' requires named parameters"],
        [spec([]), "a", "Scope 'window' does not accept arguments"]
      ]

      cases.each do |entry, raw, message|
        expect { Rhino::ScopeSpec.bind("window", entry, raw) }
          .to raise_error(Rhino::InvalidScopeArgumentsError, message)
      end
    end

    it "still underscores scope parameter names" do
      expect(Rhino::ScopeSpec.bind("window", spec(%w[from_date]), { "fromDate" => "x" })).to eq(["x"])
    end

    it "raises a different exception class per subject" do
      expect { Rhino::ScopeSpec.bind("w", spec([]), "a") }
        .to raise_error(Rhino::InvalidScopeArgumentsError)
      expect { Rhino::ComputedAttributeSpec.bind("w", spec([]), "a") }
        .to raise_error(Rhino::InvalidComputedAttributeArgumentsError)
    end
  end

  describe ".normalize_params" do
    it "stringifies names and prunes optional entries that are not parameters" do
      expect(described_class.normalize_params(%i[from to], %i[to ghost]))
        .to eq(params: %w[from to], optional: %w[to])
    end

    it "tolerates nils" do
      expect(described_class.normalize_params(nil, nil)).to eq(params: [], optional: [])
    end
  end
end

# The declaration-detection rule. A value is an extended spec if and only if it
# is a hash carrying params/optional/with. Everything else stays a LEGACY
# declaration — that is what keeps 'version' => 3 and 'tags' => %w[a b] literal
# values rather than silently becoming parameter lists.
RSpec.describe Rhino::ComputedAttributeSpec do
  describe ".normalize" do
    it "keeps a callable declaration legacy" do
      fn = ->(_record, _user) { 1 }

      expect(described_class.normalize("count" => fn))
        .to eq("count" => { params: [], optional: [], target: fn })
    end

    it "keeps a scalar literal declaration legacy" do
      specs = described_class.normalize("version" => 3, "label" => "v3")

      expect(specs["version"]).to eq(params: [], optional: [], target: 3)
      expect(specs["label"]).to eq(params: [], optional: [], target: "v3")
    end

    it "keeps a plain array a literal, NOT a parameter list" do
      # This is why computed attributes deliberately have no list shorthand:
      # %w[a b] is a legal value today.
      expect(described_class.normalize("tags" => %w[a b]))
        .to eq("tags" => { params: [], optional: [], target: %w[a b] })
    end

    it "keeps a hash without the reserved keys a literal" do
      literal = { "color" => "red", "size" => 2 }

      expect(described_class.normalize("meta" => literal))
        .to eq("meta" => { params: [], optional: [], target: literal })
    end

    it "treats a hash carrying params as an extended spec" do
      fn = ->(_scope, _user, _from, _to) { 1 }
      specs = described_class.normalize("revenue" => { params: %i[from to], with: fn })

      expect(specs["revenue"]).to eq(params: %w[from to], optional: [], target: fn)
    end

    it "accepts string keys in the spec hash" do
      fn = ->(_scope, _user, _from) { 1 }
      specs = described_class.normalize("revenue" => { "params" => ["from"], "with" => fn })

      expect(specs["revenue"]).to eq(params: %w[from], optional: [], target: fn)
    end

    it "treats a hash carrying only with: as an extended spec with no parameters" do
      fn = ->(_scope, _user) { 1 }

      expect(described_class.normalize("count" => { with: fn }))
        .to eq("count" => { params: [], optional: [], target: fn })
    end

    it "discards optional entries that are not declared parameters" do
      specs = described_class.normalize("revenue" => { params: %i[from to], optional: %i[to ghost] })

      expect(specs["revenue"][:optional]).to eq(%w[to])
    end

    it "stringifies attribute names" do
      expect(described_class.normalize(revenue: 1).keys).to eq(%w[revenue])
    end

    it "returns an empty hash for a non-hash declaration" do
      expect(described_class.normalize(nil)).to eq({})
      expect(described_class.normalize([1, 2])).to eq({})
    end
  end

  describe ".spec?" do
    it "detects only hashes carrying a reserved key" do
      expect(described_class.spec?("x")).to be(false)
      expect(described_class.spec?(3)).to be(false)
      expect(described_class.spec?(nil)).to be(false)
      expect(described_class.spec?(%w[a b])).to be(false)
      expect(described_class.spec?("color" => "red")).to be(false)
      expect(described_class.spec?(params: [])).to be(true)
      expect(described_class.spec?(optional: [])).to be(true)
      expect(described_class.spec?(with: -> { 1 })).to be(true)
      expect(described_class.spec?("params" => [])).to be(true)
    end
  end

  describe ".requires_arguments?" do
    it "is true only when a parameter is mandatory" do
      expect(described_class.requires_arguments?(params: [], optional: [])).to be(false)
      expect(described_class.requires_arguments?(params: %w[a], optional: %w[a])).to be(false)
      expect(described_class.requires_arguments?(params: %w[a], optional: [])).to be(true)
      expect(described_class.requires_arguments?(params: %w[a b], optional: %w[b])).to be(true)
    end
  end

  describe ".parameterised?" do
    it "is true whenever any parameter is declared, optional or not" do
      expect(described_class.parameterised?(params: [], optional: [])).to be(false)
      expect(described_class.parameterised?(params: %w[a], optional: %w[a])).to be(true)
    end
  end

  describe ".names" do
    it "lists every declaration" do
      expect(described_class.names("a" => -> { 1 }, "b" => { params: %w[x] })).to eq(%w[a b])
    end
  end
end
