class Hash
  def to_struct
    OpenStruct.new(self.each_with_object({}) do |(key, val), acc|
      acc[key] = val.is_a?(Hash) ? val.to_struct : val
    end)
  end
end