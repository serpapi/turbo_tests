module CoreExtensions
  refine Hash do
    def to_struct
      Struct.new(*keys).new(*values.map { |value| value.is_a?(Hash) ? value.to_struct : value })
    end
  end
end
