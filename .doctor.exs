%Doctor.Config{
  exception_moduledoc_required: true,
  failed: false,
  ignore_modules: [
    ~r/\.Application$/,
    ~r/\.SessionRegistry\.Server$/
  ],
  ignore_paths: [],
  min_module_doc_coverage: 100,
  min_module_spec_coverage: 0,
  min_overall_doc_coverage: 90,
  min_overall_spec_coverage: 0,
  min_overall_moduledoc_coverage: 100,
  raise: false,
  reporter: Doctor.Reporters.Full,
  struct_type_spec_required: false,
  umbrella: false
}
