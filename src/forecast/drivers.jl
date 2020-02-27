"""
```
prepare_forecast_inputs!(m, input_type, cond_type, output_vars;
    df = DataFrame(), verbose = :none)
```

Add required outputs using `add_requisite_output_vars` and load data if
necessary.

### Inputs

- `m::AbstractDSGEModel`: model object
- `input_type::Symbol`: See `?forecast_one`.
- `cond_type::Symbol`: See `?forecast_one`.
- `output_vars::Vector{Symbol}`: vector of desired output variables. See
  `?forecast_one_draw`

### Keyword Arguments

- `df::DataFrame`: historical data. If `cond_type in [:semi, :full]`, then the
   final row of `df` should be the period containing conditional data. If not
   provided, then `df` will be loaded using `load_data` with the appropriate
   `cond_type`
- `verbose::Symbol`: desired frequency of function progress messages printed to
  standard out. One of `:none`, `:low`, or `:high`

### Outputs

- `output_vars`
- `df`
"""
function prepare_forecast_inputs!(m::AbstractDSGEModel{S},
    input_type::Symbol, cond_type::Symbol, output_vars::Vector{Symbol};
    df::DataFrame = DataFrame(), subset_inds::AbstractRange{Int64} = 1:0,
    check_empty_columns::Bool = true, bdd_fcast::Bool = true,
    verbose::Symbol = :none) where {S<:AbstractFloat}

    # Compute everything that will be needed to plot original output_vars
    output_vars = add_requisite_output_vars(output_vars; bdd_fcast = bdd_fcast)
    if input_type == :prior
        output_vars = setdiff(output_vars, [:bddforecastobs])
    end

    # Get products and classes computed
    output_prods   = unique(map(get_product, output_vars))
    output_classes = unique(map(get_class,   output_vars))

    # Throw error if input_type = :subset but no subset_inds provided
    if input_type == :subset && isempty(subset_inds)
        error("Must supply nonempty subset_inds if input_type = :subset")
    end

    # Throw error if trying to compute shock decompositions under an alternative
    # policy rule
    if alternative_policy(m).key != :historical &&
        any(prod -> prod in [:shockdec, :dettrend, :trend], output_prods)

        error("Only histories, forecasts, and IRFs can be computed under an alternative policy")
    end

    # Determine if we are only running IRFs. If so, we won't need to load data
    # below
    irfs_only = all(prod -> prod == :irf, output_prods)

    # Load data if not provided, else check data well-formed
    if !irfs_only
        if isempty(df)
            data_verbose = verbose == :none ? :none : :low
            df = load_data(m; cond_type = cond_type, try_disk = true, check_empty_columns = check_empty_columns, verbose = data_verbose)
        else
            @assert df[1, :date] == date_presample_start(m)
            @assert df[end, :date] == (cond_type == :none ? date_mainsample_end(m) : date_conditional_end(m))
        end
    end

    return output_vars, df
end

"""
```
load_draws(m, input_type; subset_inds = 1:0, verbose = :low)

load_draws(m, input_type, block_inds; verbose = :low)
```

Load and return parameter draws from Metropolis-Hastings or SMC.

### Inputs

- `m::AbstractDSGEModel`: model object
- `input_type::Symbol`: one of the options for `input_type` described in the
  documentation for `forecast_one`
- `block_inds::AbstractRange{Int64}`: indices of the current block (already indexed by
  `jstep`) to be read in. Only used in second method

### Keyword Arguments

- `subset_inds::AbstractRange{Int64}`: indices specifying the subset of draws to be read
  in. Only used in first method
- `verbose::Symbol`: desired frequency of function progress messages printed to
  standard out. One of `:none`, `:low`, or `:high`. If `:low` or greater, prints
  location of input file.

### Outputs

- `params`: first method returns a single parameter draw of type
  `Vector{Float64}`. Second method returns a `Vector{Vector{Float64}}` of
  parameter draws for this block.
"""
function load_draws(m::AbstractDSGEModel, input_type::Symbol; subset_inds::AbstractRange{Int64} = 1:0,
                    verbose::Symbol = :low, filestring_addl::Vector{String} = Vector{String}(undef, 0), use_highest_posterior_value::Bool = false,
                    input_file_name::String = "")

    if isempty(input_file_name)
        input_file_name = get_forecast_input_file(m, input_type, filestring_addl = filestring_addl)
    end
    println(verbose, :low, "Loading draws from $input_file_name")

    # Load single draw
    if input_type in [:mean, :mode, :mode_draw_shocks]
        if get_setting(m, :sampling_method) == :MH
            params = convert(Vector{Float64}, h5read(input_file_name, "params"))
        elseif get_setting(m, :sampling_method) == :SMC
            if input_type in [:mode, :mode_draw_shocks]
                # If mode is in forecast overrides, want to use the file specified
                if :mode in collect(keys(forecast_input_file_overrides(m)))
                    params = convert(Vector{Float64}, h5read(input_file_name, "params"))
                    # If not, load it from the cloud
                elseif occursin("smc_paramsmode", input_file_name) && !use_highest_posterior_value
                    params = convert(Vector{Float64}, h5read(input_file_name, "params"))
                else
                    input_file_name = replace(replace(input_file_name,
                                                      "smc_paramsmode" => "smc_cloud"),
                                              ".h5" => ".jld2")
                    println(verbose, :low, "Switching estimation file of draws to $input_file_name")
                    cloud = load(input_file_name, "cloud")

                    params = get_vals(cloud)[:, argmax(get_logpost(cloud))]
                end
            else
                error("SMC mean not implemented yet")
            end
        else
            error("Invalid :sampling method specification. Change in setting :sampling_method")
        end
    # Load full distribution
    elseif input_type == :full

        if get_setting(m, :sampling_method) == :MH
            params = map(Float64, h5read(input_file_name, "mhparams"))
        elseif get_setting(m, :sampling_method) == :SMC
            cloud = load(replace(replace(input_file_name, ".h5" => ".jld2"), "smcsave" => "smc_cloud"), "cloud")
            params_unweighted = get_vals(cloud)

            # Re-sample SMC draws according to their weights
            W = load(replace(replace(input_file_name, "smcsave" => "smc_cloud"), "h5" => "jld2"), "W")
            weights = W[:, end]
            inds = resample(weights)

            params = Matrix{Float64}(params_unweighted[:, inds]')
        else
            error("Invalid :sampling method specification. Change in setting :sampling_method")
        end

    # Load subset of full distribution
    elseif input_type == :subset

        if isempty(subset_inds)
            error("Must supply nonempty range of subset_inds if input_type == :subset")
        else
            if get_setting(m, :sampling_method) == :MH
                params = map(Float64, h5read(input_file_name, "mhparams", (subset_inds, :)))
            elseif get_setting(m, :sampling_method) == :SMC
                params = map(Float64, h5read(input_file_name, "smcparams", (subset_inds, :)))
            else
                throw("Invalid :sampling method specification. Change in setting :sampling_method")
            end
        end
    elseif input_type == :prior
        params = rand(m.parameters, n_forecast_draws(m, :prior))
    # Return initial parameters of model object
    elseif input_type == :init || input_type == :init_draw_shocks

#=        if m.spec == "het_dsge"
            init_parameters!(m, testing_gamma = false)
        else
            init_parameters!(m)
        end =#
        tmp = map(α -> α.value, m.parameters)
        params = convert(Vector{Float64}, tmp)

    end

    return params
end

function load_draws(m::AbstractDSGEModel, input_type::Symbol, block_inds::AbstractRange{Int64};
                    verbose::Symbol = :low, filestring_addl::Vector{String} = Vector{String}(undef, 0),
                    input_file_name::String = "")

    if isempty(input_file_name)
        input_file_name = get_forecast_input_file(m, input_type, filestring_addl = filestring_addl)
    end
    println(verbose, :low, "Loading draws from $input_file_name")

    if input_type in [:full, :subset]
        if isempty(block_inds)
            error("Must supply nonempty range of block_inds for this load_draws method")
        else
            ndraws = length(block_inds)
            params = Vector{Vector{Float64}}(undef, ndraws)
            if get_setting(m, :sampling_method) == :SMC
                params_unweighted = similar(params)
            end
            for (i, j) in zip(1:ndraws, block_inds)
                if get_setting(m, :sampling_method) == :MH
                    params[i] = vec(map(Float64, h5read(input_file_name, "mhparams", (j, :))))
                elseif get_setting(m, :sampling_method) == :SMC

                    params_unweighted[i] = vec(map(Float64, h5read(input_file_name, "smcparams", (j, :))))
                else
                    throw("Invalid :sampling_method setting specification.")
                end
            end

            # Re-sample draws according to weights if the sampling_method was SMC
            if get_setting(m, :sampling_method) == :SMC
                # Re-sample SMC draws according to their weights
                @load replace(replace(input_file_name, "smcsave" => "smc_cloud"), "h5" => "jld2") W
                weights = W[:, end][block_inds]
                inds = resample(weights)

                params = params_unweighted[inds]
            end

            return params
        end
    elseif input_type == :init_draw_shocks
        ndraws = length(block_inds)
        params = repeat([map(x -> x.value, m.parameters)], ndraws)
    elseif input_type == :mode_draw_shocks
        ndraws = length(block_inds)
        params = repeat([map(x -> x.value, m.parameters)], ndraws)
    elseif input_type == :prior
        ndraws = length(block_inds)
        params = Vector{Vector{Float64}}(undef, ndraws)
        for (i, j) in zip(1:ndraws, block_inds)
            try_again = true
            param_try = vec(rand(m.parameters, ndraws)[:, i])
            # Need to do this to ensure that draws from prior don't return -Inf likelihood
            while try_again
                param_try = vec(rand(m.parameters, ndraws)[:, i])
                try
                    update!(m, param_try)
                    likelihood(m, rand(length(m.observables), 100))
                    try_again = false
                catch
                    try_again = true
                end
            end
            params[i] = param_try
        end
        return params
    else
        error("This load_draws method can only be called with input_type in [:full, :subset]")
    end
end

function load_draws(m::DSGEVAR, input_type::Symbol; subset_inds::AbstractRange{Int64} = 1:0,
                    verbose::Symbol = :low,
                    filestring_addl::Vector{String} = Vector{String}(undef, 0),
                    input_file_name::String = "")

    if isempty(input_file_name)
        input_file_name = get_forecast_input_file(m, input_type;
                                                  filestring_addl = filestring_addl)
    end

    return load_draws(m.dsge, input_type; subset_inds = subset_inds, verbose = verbose,
                      filestring_addl = filestring_addl,
                      input_file_name = input_file_name)
end

"""
```
forecast_one(m, input_type, cond_type, output_vars; df = DataFrame(),
    subset_inds = 1:0, forecast_string = "", verbose = :low)
```

Compute and save `output_vars` for input draws given by `input_type` and
conditional data case given by `cond_type`.

### Inputs

- `m::AbstractDSGEModel`: model object

- `input_type::Symbol`: one of:

```
  - `:mode`: forecast using the modal parameters only
  - `:mean`: forecast using the mean parameters only
  - `:init`: forecast using the initial parameter values only
  - `:full`: forecast using all parameters (full distribution)
  - `:subset`: forecast using a well-defined user-specified subset of draws
```

- `cond_type::Symbol`: one of:

```
  - `:none`: no conditional data
  - `:semi`: use \"semiconditional data\" - average of quarter-to-date
    observations for high frequency series
  - `:full`: use \"conditional data\" - semiconditional plus nowcasts for
    desired observables
```

- `output_vars::Vector{Symbol}`: vector of desired output variables. See
  `?forecast_one_draw`.

### Keyword Arguments

- `df::DataFrame`: Historical data. If `cond_type in [:semi, :full]`, then the
   final row of `df` should be the period containing conditional data. If not
   provided, will be loaded using `load_data` with the appropriate `cond_type`
- `subset_inds::AbstractRange{Int64}`: indices specifying the draws we want to use. If a
  more sophisticated selection criterion is desired, the user is responsible for
  determining the indices corresponding to that criterion. If `input_type` is
  not `subset`, `subset_inds` will be ignored
- `forecast_string::String`: short string identifying the subset to be
  appended to the output filenames. If `input_type = :subset` and
  `forecast_string` is empty, an error is thrown.
- `verbose::Symbol`: desired frequency of function progress messages printed to
  standard out. One of `:none`, `:low`, or `:high`.
- `cond_obs_shocks::Dict{Symbol,Float64}`: See `?forecast_one_draw`.

### Outputs

None. Output is saved to files returned by
`get_forecast_output_files(m, input_type, cond_type, output_vars)`.
"""
function forecast_one(m::AbstractDSGEModel{Float64},
                      input_type::Symbol, cond_type::Symbol, output_vars::Vector{Symbol};
                      df::DataFrame = DataFrame(), subset_inds::AbstractRange{Int64} = 1:0,
                      forecast_string::String = "", verbose::Symbol = :low,
                      use_filtered_shocks_in_shockdec::Bool = false,
                      shock_name::Symbol = :none,
                      shock_var_name::Symbol = :none,
                      shock_var_value::Float64 = 0.0,
                      check_empty_columns = true,
                      cond_obs_shocks::Dict{Symbol,Float64} = Dict{Symbol,Float64}(),
                      smooth_conditional::Symbol = :hist_cond,
                      cond_deviation_shocks::Vector{Symbol} = collect(keys(m.exogenous_shocks)),
                      bdd_fcast::Bool = true)

    ### Common Setup

    # Add necessary output_vars and load data
    output_vars, df = prepare_forecast_inputs!(m, input_type, cond_type, output_vars;
                                               df = df, verbose = verbose,
                                               subset_inds = subset_inds,
                                               check_empty_columns = check_empty_columns,
                                               bdd_fcast = bdd_fcast)

    # Get output file names
    forecast_output = Dict{Symbol, Array{Float64}}()
    forecast_output_files = get_forecast_output_files(m, input_type, cond_type, output_vars;
                                                      forecast_string = forecast_string)

    if !isempty(cond_obs_shocks) && all(prod -> prod == :irf, map(x->get_product(x), output_vars))
        @warn "The input variable output_vars includes only IRFs. Skipping computation of conditional forecast on shocks to observables."
        cond_obs_shocks = Dict{Symbol,Float64}()
    end

    if !isempty(cond_obs_shocks)
        cond_forecast_output_files =
            get_forecast_output_files(m, input_type, cond_type,
                                      setdiff(output_vars,
                                              [:shockdecobs, :shockdecstates,
                                               :shockdecpseudo,
                                               :dettrendobs, :dettrendpseudo,
                                               :trendobs, :trendpseudo,
                                               :dettrendstates, :trendstates]);
                                      forecast_string = forecast_string,
                                      do_cond_obs_shocks = true)
    end

    output_dir = rawpath(m, "forecast")

    # Print
    info_print(verbose, :low, "Forecasting input_type = $input_type, cond_type = $cond_type...")
    println(verbose, :low, "Start time: $(now())")
    println(verbose, :low, "Forecast outputs will be saved in $output_dir")


    ### Single-Draw Forecasts

    if input_type in [:mode, :mean, :init]

        elapsed_time = @elapsed let
            params = load_draws(m, input_type; verbose = verbose)
            if isempty(cond_obs_shocks)
                forecast_output = forecast_one_draw(m, input_type, cond_type, output_vars,
                                                    params, df, verbose = verbose,
                                                    shock_name = shock_name,
                                                    shock_var_name = shock_var_name,
                                                    shock_var_value = shock_var_value,
                                                    smooth_conditional = smooth_conditional,
                                                    cond_deviation_shocks =
                                                    cond_deviation_shocks)
            else
                forecast_output, cond_forecast_output =
                    forecast_one_draw(m, input_type, cond_type, output_vars,
                                      params, df, cond_obs_shocks, verbose = verbose,
                                      shock_name = shock_name,
                                      shock_var_name = shock_var_name,
                                      shock_var_value = shock_var_value,
                                      smooth_conditional = smooth_conditional,
                                      cond_deviation_shocks =
                                      cond_deviation_shocks)

                write_forecast_outputs(m, input_type,
                                       setdiff(output_vars, [:shockdecobs, :shockdecstates,
                                                             :shockdecpseudo,
                                                             :dettrendobs, :dettrendpseudo,
                                                             :trendobs, :trendpseudo,
                                                             :dettrendstates, :trendstates]),
                                       cond_forecast_output_files,
                                       cond_forecast_output; df = df,
                                       block_number = Nullable{Int64}(),
                                       verbose = verbose)
            end
        end

        write_forecast_outputs(m, input_type, output_vars, forecast_output_files,
                               forecast_output; df = df, block_number = Nullable{Int64}(),
                               verbose = verbose)

        total_forecast_time     = elapsed_time
        total_forecast_time_min = total_forecast_time/60
        println(verbose, :low, "\nTotal time to forecast: $total_forecast_time_min minutes")


    ### Multiple-Draw Forecasts

    elseif input_type in [:full, :subset, :prior, :init_draw_shocks, :mode_draw_shocks]
        if get_setting(m, :sampling_method) == :SMC
            subset_cond = input_type == :subset && get_jstep(m, length(subset_inds)) > 1
            other_cond = input_type in [:full, :prior, :init_draw_shocks, :mode_draw_shocks] &&
                get_jstep(m, n_forecast_draws(m, :full)) > 1
            if subset_cond || other_cond
                answer = ""
                invalid_answer = true
                while invalid_answer
                    println("WARNING: The forecast draws are being thinned by $(get_jstep(m, n_forecast_draws(m,:full))). This is not recommended for forecasts using an SMC estimation. Do you want to continue? (y/n)")
                    answer = readline(stdin)
                    if (answer == "y" || answer == "n")
                        invalid_answer = false
                    else
                        println("Invalid answer! Must be `y` or `n`")
                    end
                end

                if answer == "n"
                    throw(error("Forecast halted by user."))
                end
            end
        end

        # Block info
        block_inds, block_inds_thin = forecast_block_inds(m, input_type; subset_inds = subset_inds)
        nblocks = length(block_inds)
        start_block = forecast_start_block(m)

        # Info needed for printing progress
        total_forecast_time = 0.0
        block_verbose = verbose == :none ? :none : :low

        for block = start_block:nblocks
            println(verbose, :low, )
            info_print(verbose, :low, "Forecasting block $block of $nblocks...")
            begin_time = time_ns()

            # Get to work!
            params = load_draws(m, input_type, block_inds[block]; verbose = verbose)
            mapfcn = use_parallel_workers(m) ? pmap : map
            if isempty(cond_obs_shocks)
                forecast_outputs = mapfcn(param ->
                                          forecast_one_draw(m, input_type, cond_type,
                                                            output_vars,
                                                            param, df, verbose = verbose,
                                                            use_filtered_shocks_in_shockdec =
                                                            use_filtered_shocks_in_shockdec,
                                                            shock_name = shock_name,
                                                            shock_var_name = shock_var_name,
                                                            shock_var_value = shock_var_value,
                                                            smooth_conditional = smooth_conditional,
                                                            cond_deviation_shocks =
                                                            cond_deviation_shocks),
                                          params)
            else
                forecast_outputs = mapfcn(param ->
                                          forecast_one_draw(m, input_type, cond_type,
                                                            output_vars,
                                                            param, df, cond_obs_shocks,
                                                            verbose = verbose,
                                                            use_filtered_shocks_in_shockdec =
                                                            use_filtered_shocks_in_shockdec,
                                                            shock_name = shock_name,
                                                            shock_var_name = shock_var_name,
                                                            shock_var_value = shock_var_value,
                                                            smooth_conditional = smooth_conditional,
                                                            cond_deviation_shocks =
                                                            cond_deviation_shocks),
                                          params)

                # Unwrap tuple into Vector{Dict{Symbol, Array{Float64}}}
                # and write conditional forecast output
                cond_forecast_outputs = map(x -> x[2], forecast_outputs)
                forecast_outputs = map(x -> x[1], forecast_outputs)
                cond_forecast_outputs = convert(Vector{Dict{Symbol, Array{Float64}}},
                                                cond_forecast_outputs)
                cond_forecast_output = assemble_block_outputs(cond_forecast_outputs)
                write_forecast_outputs(m, input_type,
                                       setdiff(output_vars, [:shockdecobs, :shockdecstates,
                                                             :shockdecpseudo,
                                                             :dettrendobs, :dettrendpseudo,
                                                             :trendobs, :trendpseudo,
                                                             :dettrendstates, :trendstates]),
                                       cond_forecast_output_files,
                                       cond_forecast_output; df = df,
                                       block_number = Nullable(block),
                                       verbose = block_verbose, block_inds = block_inds_thin[block],
                                       subset_inds = subset_inds)
            end

            # Assemble outputs from this block and write to file
            forecast_outputs = convert(Vector{Dict{Symbol, Array{Float64}}}, forecast_outputs)
            forecast_output = assemble_block_outputs(forecast_outputs)
            write_forecast_outputs(m, input_type, output_vars, forecast_output_files,
                                   forecast_output; df = df, block_number = Nullable(block),
                                   verbose = block_verbose, block_inds = block_inds_thin[block],
                                   subset_inds = subset_inds)
            GC.gc()

            # Calculate time to complete this block, average block time, and
            # expected time to completion
            block_time = (time_ns() - begin_time)/1e9
            total_forecast_time += block_time
            total_forecast_time_min     = total_forecast_time/60
            blocks_elapsed              = block - start_block + 1
            expected_time_remaining     = (total_forecast_time/blocks_elapsed)*(nblocks - block)
            expected_time_remaining_min = expected_time_remaining/60

            println(verbose, :low, "\nCompleted $block of $nblocks blocks.")
            println(verbose, :low, "Total time elapsed: $total_forecast_time_min minutes")
            println(verbose, :low, "Expected time remaining: $expected_time_remaining_min minutes")
        end # of loop through blocks

    end # of input_type
    if !isempty(cond_obs_shocks)
        combine_raw_forecast_output_and_metadata(m, cond_forecast_output_files,
                                                 verbose = verbose)
    end
    combine_raw_forecast_output_and_metadata(m, forecast_output_files, verbose = verbose)

    println(verbose, :low, "\nForecast complete: $(now())")
end

"""
```
forecast_one_draw(m, input_type, cond_type, output_vars; params, df;
    verbose = :low)
forecast_one_draw(m, input_type, cond_type, output_vars, cond_obs_shocks; params, df;
    verbose = :low)
```

Compute `output_vars` for a single parameter draw, `params`. Called by
`forecast_one`.

If `cond_obs_shocks` are provided, then this function computes both
the forecast requested by the pair (`input_type`, `cond_type`) and
an additional forecast that include the shocks specified by
`cond_obs_shocks` to observables in the initial forecast period.

### Inputs

- `m::AbstractDSGEModel{Float64}`: model object
- `input_type::Symbol`: See `?forecast_one`.
- `cond_type::Symbol`: See `?forecast_one`.
- `output_vars::Vector{Symbol}`: vector of desired output variables. See Outputs
  section
- `params::Vector{Float64}`: parameter vector
- `df::DataFrame`: historical data.
- `verbose::Symbol`: desired frequency of function progress messages printed to
  standard out. One of `:none`, `:low`, or `:high`.
- `cond_obs_shocks::Dict{Symbol,Float64}`: shocks to observables for conditional forecasts

### Output

- `forecast_outputs::Dict{Symbol, Array{Float64}}`: dictionary of forecast
  outputs. Keys are `output_vars`, which is some subset of:

```
  - `:histstates`: `Matrix{Float64}` of smoothed historical states
  - `:histobs`: `Matrix{Float64}` of smoothed historical data
  - `:histpseudo`: `Matrix{Float64}` of smoothed historical
    pseudo-observables
  - `:histshocks`: `Matrix{Float64}` of smoothed historical shocks
  - `:forecaststates`: `Matrix{Float64}` of forecasted states
  - `:forecastobs`: `Matrix{Float64}` of forecasted observables
  - `:forecastpseudo`: `Matrix{Float64}` of forecasted pseudo-observables
  - `:forecastshocks`: `Matrix{Float64}` of forecasted shocks
  - `:bddforecaststates`, `:bddforecastobs`, `:bddforecastpseudo`, and
    `:bddforecastshocks`: `Matrix{Float64}`s of forecasts where we enforce
    the zero lower bound to be `forecast_zlb_value(m)`
  - `:shockdecstates`: `Array{Float64, 3}` of state shock decompositions
  - `:shockdecobs`: `Array{Float64, 3}` of observable shock decompositions
  - `:shockdecpseudo`: `Array{Float64, 3}` of pseudo-observable shock
    decompositions
  - `:dettrendstates`: `Matrix{Float64}` of state deterministic trends
  - `:dettrendobs`: `Matrix{Float64}` of observable deterministic trends
  - `:dettrendpseudo`: `Matrix{Float64}` of pseudo-observable deterministic
    trends
  - `:trendstates`: `Vector{Float64}` of state trends, i.e. the `CCC` vector
  - `:trendobs`: `Vector{Float64}` of observable trends, i.e. the `DD` vector
  - `:trendpseudo`: `Vector{Float64}` of pseudo-observable trends, i.e. the
    `DD_pseudo` vector
  - `:irfstates`: `Array{Float64, 3}` of state impulse responses
  - `:irfobs`: `Array{Float64, 3}` of observable impulse responses
  - `:irfpseudo`: `Array{Float64, 3}` of pseudo-observable impulse responses
```
"""
function forecast_one_draw(m::AbstractDSGEModel{Float64}, input_type::Symbol, cond_type::Symbol,
                           output_vars::Vector{Symbol}, params::Vector{Float64}, df::DataFrame;
                           verbose::Symbol = :low,
                           use_filtered_shocks_in_shockdec::Bool = false,
                           shock_name::Symbol = :none,
                           shock_var_name::Symbol = :none,
                           shock_var_value::Float64 = 0.0,
                           smooth_conditional::Symbol = :hist_cond,
                           cond_deviation_shocks::Vector{Symbol} =
                           collect(keys(m.exogenous_shocks)),
                           cond_deviation_obs_shocks::DataFrame = DataFrame(),
                           param_key::Symbol = :nothing,
                           param_value::Float64 = 0.0,
                           param_key2::Symbol = :nothing,
                           param_value2::Float64 = 0.0)

    ### Setup

    # Re-initialize model indices if forecasting under an alternative policy
    # rule (in case new states or equations were added)
    if alternative_policy(m).key != :historical
        init_model_indices!(m)
    end

    # Are we only running IRFs?
    output_prods = map(get_product, output_vars)
    irfs_only = all(x -> x == :irf, output_prods)

    # Compute state space
    update!(m, params)
    system = compute_system(m)

    # Initialize output dictionary
    forecast_output = Dict{Symbol, Array{Float64}}()

    # Decide whether to draw states/shocks in smoother/forecast
    uncertainty_override = forecast_uncertainty_override(m)
    uncertainty = if Nullables.isnull(uncertainty_override)
        if input_type in [:init, :mode, :mean, :prior]
            false
        elseif input_type in [:full, :subset, :mode_draw_shocks, :init_draw_shocks]
            true
        end
    else
        get(uncertainty_override)
    end

    ### 1. Smoothed Histories

    # Must run smoother for conditional data in addition to explicit cases
    hist_vars = [:histstates, :histpseudo, :histshocks, :histstdshocks]
    shockdec_vars = [:shockdecstates, :shockdecpseudo, :shockdecobs]
    dettrend_vars = [:dettrendstates, :dettrendpseudo, :dettrendobs]
    smooth_vars = vcat(hist_vars, shockdec_vars, dettrend_vars)
    hists_to_compute = intersect(output_vars, smooth_vars)

    run_smoother = !isempty(hists_to_compute) ||
        (cond_type in [:semi, :full] && !irfs_only)

    if run_smoother
        # Call smoother on history and/or conditional data
        # If smooth_conditional is not :hist_cond, then we will compute
        # the forecast using deviations of a conditional
        # forecast from an unconditional forecast.
        # Note that if we set cond_type = :none, then
        # even if the last row of df contains conditional data,
        # it will be ignored during smoothing
        histstates, histshocks, histpseudo, initial_states =
            smooth(m, df, system;
                   cond_type = smooth_conditional == :hist_cond ? cond_type : :none,
                   draw_states = uncertainty)

        # For conditional data, transplant the obs/state/pseudo vectors from hist to forecast
        if cond_type in [:full, :semi]  # still true even if
            T = n_mainsample_periods(m) # smooth_conditional != :hist_cond

            forecast_output[:histstates] = transplant_history(histstates, T)
            forecast_output[:histshocks] = transplant_history(histshocks, T)
            forecast_output[:histpseudo] = transplant_history(histpseudo, T)
        else
            forecast_output[:histstates] = histstates
            forecast_output[:histshocks] = histshocks
            forecast_output[:histpseudo] = histpseudo
        end

        # Standardize shocks if desired
        if :histstdshocks in output_vars
            forecast_output[:histstdshocks] = standardize_shocks(forecast_output[:histshocks], system[:QQ])
        end

        if smooth_conditional != :hist_cond && cond_type in [:semi, :full]
            date_start = date_forecast_start(m) # when forecast & conditional start
            date_end   = date_conditional_end(m) # when conditional data end

            # Compute unconditional forecasts over conditional data dates
            _, uncondobs, _ = forecast(system, histstates[:,end],
                                       zeros(n_shocks_exogenous(m), subtract_quarters(date_start, date_end) + 1);
                                       enforce_zlb = false)

            # Compute deviations from unconditional forecast
            if smooth_conditional == :cond
                # Infer deviations from df
                cond_df = df[date_start .<= df[!,:date] .<= date_end, :]
                for i = 2:size(cond_df,2)
                    cond_df[:,i] -= (system[:measurement][:DD] +
                        system[:measurement][:ZZ] * uncondobs[i-1,:])
                end
            elseif smooth_conditional == :deviations
                if isempty(cond_deviation_obs_shocks)
                    error("The DataFrame `cond_deviation_obs_shocks` cannot be empty if smooth_conditional " *
                          "is set to :deviations")
                end
                cond_df =
                    cond_deviation_obs_shocks[date_start .<=
                                              cond_deviation_obs_shocks[!,:date] .<= date_end, :]
            else
                error("Keyword smooth_conditional cannot be $smooth_conditional. The options " *
                      "are :hist_cond, :cond, and :deviations")
            end

            system_deviation = compute_deviations_system(m, system, cond_deviation_shocks)
            _, forecast_deviation_shocks, _ =
                smooth(m, cond_df, system_deviation, zeros(n_states_augmented(m)),
                       zeros(n_states_augmented(m), n_states_augmented(m));
                       cond_type = cond_type, draw_states = uncertainty,
                       include_presample = true, in_sample = false)
        end
    end

    ### 2. Forecasts

    unbddforecast_vars = [:forecaststates, :forecastobs, :forecastpseudo, :forecastshocks, :forecaststdshocks]
    bddforecast_vars = [:bddforecaststates, :bddforecastobs, :bddforecastpseudo, :bddforecastshocks, :bddforecaststdshocks]
    forecast_vars = vcat(unbddforecast_vars, bddforecast_vars)
    forecasts_to_compute = intersect(output_vars, forecast_vars)

    if !isempty(forecasts_to_compute)
        # Get initial forecast state vector s_T
        s_T = if run_smoother
            # The last smoothed state is either s_{T|T} (if !uncertainty) or
            # drawn from N(s_{T|T}, P_{T|T}) (if uncertainty)
            histstates[:, end]
        else
            kal = Kalman(Vector{Float64}(undef,0), Matrix{Float64}(undef, 0, 0), Array{Float64}(undef, 0, 0, 0), Matrix{Float64}(undef, 0, 0), Array{Float64}(undef, 0, 0, 0), Vector{Float64}(undef, 0), Array{Float64}(undef, 0, 0, 0), Vector{Float64}(undef, 0), Array{Float64}(undef, 0, 0, 0))
            try
                kal = filter(m, df, system; cond_type = cond_type)
            catch err
                if isa(err, DomainError)
                    return Dict{Symbol, Array{Float64}}()
                else
                    rethrow(err)
                end
            end
            if uncertainty
                # If we want to draw s_T but haven't run the smoother, draw from
                # N(s_{T|T}, P_{T|T}) directly
                U, singular_values, _ = svd(kal[:P_T])
                dist = DegenerateMvNormal(kal[:s_T], U*Matrix(Diagonal(sqrt.(singular_values))))
                rand(dist)
            else
                # If we don't want to draw s_T, simply use the mean s_{T|T}
                kal[:s_T]
            end
        end
        if param_key!=:nothing
            m[param_key] = param_value
            steadystate!(m)
            system = compute_system(m)
        end
        if param_key2!=:nothing
            m[param_key2] = param_value2
            steadystate!(m)
            system = compute_system(m)
        end


        # Re-solve model with alternative policy rule, if applicable
        if alternative_policy(m).solve != identity
            system = compute_system(m; apply_altpolicy = true)
        end

        # 2A. Unbounded forecasts
        if !isempty(intersect(output_vars, unbddforecast_vars))

            forecaststates, forecastobs, forecastpseudo, forecastshocks =
                if smooth_conditional != :hist_cond && cond_type in [:semi, :full]
                    forecast(m, system, s_T; shocks = forecast_deviation_shocks,
                             enforce_zlb = false, cond_type = :none, draw_shocks = uncertainty)
                    # Must set cond_type to none, or you won't compute enough
                    # forecasts. This is because hist_cond computes at least
                    # the first forecast period
                else
                    forecast(m, system, s_T;
                             cond_type = cond_type, enforce_zlb = false, draw_shocks = uncertainty)
                end

            # For conditional data when the smoother is run on history and conditional data,
            # transplant the obs/state/pseudo vectors from hist to forecast
            if smooth_conditional == :hist_cond && cond_type in [:full, :semi]
                forecast_output[:forecaststates] = transplant_forecast(histstates, forecaststates, T)
                forecast_output[:forecastshocks] = transplant_forecast(histshocks, forecastshocks, T)
                forecast_output[:forecastpseudo] = transplant_forecast(histpseudo, forecastpseudo, T)
                forecast_output[:forecastobs]    = transplant_forecast_observables(histstates, forecastobs, system, T)
            else
                forecast_output[:forecaststates] = forecaststates
                forecast_output[:forecastshocks] = forecastshocks
                forecast_output[:forecastpseudo] = forecastpseudo
                forecast_output[:forecastobs]    = forecastobs
            end

            # Standardize shocks if desired
            if :forecaststdshocks in output_vars
                forecast_output[:forecaststdshocks] = standardize_shocks(forecast_output[:forecastshocks], system[:QQ])
            end
        end

        # 2B. Bounded forecasts

        if !isempty(intersect(output_vars, bddforecast_vars))
            forecaststates, forecastobs, forecastpseudo, forecastshocks =
                if smooth_conditional != :hist_cond && cond_type in [:semi, :full]
                    forecast(m, system, s_T; shocks = forecast_deviation_shocks,
                             enforce_zlb = true, cond_type = :none, draw_shocks = uncertainty)
                else
                    forecast(m, system, s_T;
                             cond_type = cond_type, enforce_zlb = true, draw_shocks = uncertainty)
                end

            # For conditional data, transplant the obs/state/pseudo vectors from hist to forecast
            if cond_type in [:full, :semi]
                forecast_output[:bddforecaststates] = transplant_forecast(histstates, forecaststates, T)
                forecast_output[:bddforecastshocks] = transplant_forecast(histshocks, forecastshocks, T)
                forecast_output[:bddforecastpseudo] = transplant_forecast(histpseudo, forecastpseudo, T)
                forecast_output[:bddforecastobs]    = transplant_forecast_observables(histstates, forecastobs, system, T)
            else
                forecast_output[:bddforecaststates] = forecaststates
                forecast_output[:bddforecastshocks] = forecastshocks
                forecast_output[:bddforecastpseudo] = forecastpseudo
                forecast_output[:bddforecastobs]    = forecastobs
            end

            # Standardize shocks if desired
            if :bddforecaststdshocks in output_vars
                forecast_output[:bddforecaststdshocks] = standardize_shocks(forecast_output[:bddforecastshocks], system[:QQ])
            end
        end
    end


    ### 3. Shock Decompositions

    shockdecs_to_compute = intersect(output_vars, shockdec_vars)

    if !isempty(shockdecs_to_compute)

        histshocks_shockdec = if use_filtered_shocks_in_shockdec
            filter_shocks(m, df, system, cond_type = cond_type)
        else
            histshocks
        end

        shockdecstates, shockdecobs, shockdecpseudo = shock_decompositions(m, system, histshocks_shockdec)

        forecast_output[:shockdecstates] = shockdecstates
        forecast_output[:shockdecobs]    = shockdecobs
        forecast_output[:shockdecpseudo] = shockdecpseudo
    end

    ### 4. Trend

    trend_vars = [:trendstates, :trendobs, :trendpseudo]
    trends_to_compute = intersect(output_vars, trend_vars)

    if !isempty(trends_to_compute)
        trendstates, trendobs, trendpseudo = trends(system)

        forecast_output[:trendstates] = trendstates
        forecast_output[:trendobs]    = trendobs
        forecast_output[:trendpseudo] = trendpseudo
    end


    ### 5. Deterministic Trend
    dettrends_to_compute = intersect(output_vars, dettrend_vars)

    if !isempty(dettrends_to_compute)
        dettrendstates, dettrendobs, dettrendpseudo = deterministic_trends(m, system, initial_states)

        forecast_output[:dettrendstates] = dettrendstates
        forecast_output[:dettrendobs]    = dettrendobs
        forecast_output[:dettrendpseudo] = dettrendpseudo
    end


    ### 6. Impulse Responses
    irf_vars = [:irfstates, :irfobs, :irfpseudo]
    irfs_to_compute = intersect(output_vars, irf_vars)

    if !isempty(irfs_to_compute)
        if shock_name!=:none
            irfstates, irfobs, irfpseudo = impulse_responses(m, system, impulse_response_horizons(m),
                                                             shock_name,
                                                             shock_var_name,
                                                             shock_var_value)
        else
            irfstates, irfobs, irfpseudo = impulse_responses(m, system)
        end
        forecast_output[:irfstates] = irfstates
        forecast_output[:irfobs] = irfobs
        forecast_output[:irfpseudo] = irfpseudo
    end


    ### Return only desired output_vars
    for key in keys(forecast_output)
        if !(key in output_vars)
            delete!(forecast_output, key)
        end
    end
    return forecast_output
end

function forecast_one_draw(m::AbstractDSGEModel{Float64}, input_type::Symbol, cond_type::Symbol,
                           output_vars::Vector{Symbol}, params::Vector{Float64}, df::DataFrame,
                           cond_obs_shocks::Dict{Symbol,Float64};
                           verbose::Symbol = :low,
                           use_filtered_shocks_in_shockdec::Bool = false,
                           shock_name::Symbol = :none,
                           shock_var_name::Symbol = :none,
                           shock_var_value::Float64 = 0.0,
                           smooth_conditional::Symbol = :hist_cond,
                           cond_deviation_shocks::Vector{Symbol} =
                           collect(keys(m.exogenous_shocks)))

    # Compute unconditional forecast
    tmp_output_vars = copy(output_vars)
    if !(:forecastobs in output_vars)
        push!(tmp_output_vars, :forecastobs)
    end
    uncond_forecast_output = forecast_one_draw(m, input_type, cond_type, tmp_output_vars,
                                               params, df, verbose = verbose,
                                               shock_name = shock_name,
                                               shock_var_name = shock_var_name,
                                               shock_var_value = shock_var_value,
                                               smooth_conditional = :hist_cond)

    # don't compute shockdecs for conditional fcast
    output_var_prod = map(x -> get_product(x), output_vars)
    if :shockdec in output_var_prod
        output_vars = setdiff(output_vars, [:shockdecobs, :shockdecstates, :shockdecpseudo,
                                            :dettrendobs, :dettrendpseudo, :trendobs,
                                            :trendpseudo, :dettrendstates, :trendstates])
    end

    # Prepare conditional data and run conditional forecast
    if smooth_conditional in [:hist_cond, :cond]
        # Data
        cond_df = copy(df)
        if cond_type in [:semi, :full] # then last row is already forecast of future period
            for (obs,shock) in cond_obs_shocks
                if ismissing(cond_df[end,obs]) # then need to add unconditional forecast first
                    ind = findfirst(setdiff(names(cond_df), [:date]) .== obs)
                    cond_df[end,obs] = uncond_forecast_output[:forecastobs][ind,1]
                end
                cond_df[end,obs] += shock
            end
        else # then we need to construct new row
            newrow = Vector{Union{Date,Float64}}(undef,size(cond_df,2))
            newrow[1] = date_forecast_start(m)
            newrow[2:end] = uncond_forecast_output[:forecastobs][:,1]
            push!(cond_df, newrow) # add unconditional forecasts
            for (obs,shock) in cond_obs_shocks # add conditional shocks
                cond_df[end,obs] += shock
            end
            non_shock_cols = setdiff(setdiff(names(cond_df), [:date]), keys(cond_obs_shocks))
            nrows = size(cond_df,1)
            for col in non_shock_cols # set to missing any observables without conditional shocks
                newcol = Vector{Union{Float64,Missing}}(undef,nrows)
                newcol[1:end-1] = cond_df[1:end-1,col]
                newcol[end] = missing
                cond_df[!,col] = newcol
            end
        end

        # Conditional forecast
        # Must set cond_type to :semi or :full here, or you won't get a conditional forecast
        cond_forecast_output = forecast_one_draw(m, input_type, cond_type in [:semi,:full] ?
                                                 cond_type : :full, output_vars,
                                                 params, cond_df, verbose = verbose,
                                                 shock_name = shock_name,
                                                 shock_var_name = shock_var_name,
                                                 shock_var_value = shock_var_value,
                                                 smooth_conditional = smooth_conditional,
                                                 cond_deviation_shocks = cond_deviation_shocks)
    elseif smooth_conditional == :deviations
        cond_df = df
        cond_deviation_obs_shocks =
            DataFrame(date = DSGE.get_quarter_ends(date_forecast_start(m),
                                                   date_conditional_end(m)))
        # nrows = n_conditional_periods(m) # to be added back in for generalization
        for col in setdiff(names(cond_df), [:date])
            # cond_deviation_obs_shocks[end-nrows+1:end,col] = # to be added in generalization
            cond_deviation_obs_shocks[!,col] .=
                haskey(cond_obs_shocks, col) ? cond_obs_shocks[col] : missing
        end
        cond_forecast_output = forecast_one_draw(m, input_type, cond_type in [:semi,:full] ?
                                                 cond_type : :full, output_vars,
                                                 params, cond_df, verbose = verbose,
                                                 shock_name = shock_name,
                                                 shock_var_name = shock_var_name,
                                                 shock_var_value = shock_var_value,
                                                 smooth_conditional = smooth_conditional,
                                                 cond_deviation_shocks = cond_deviation_shocks,
                                                 cond_deviation_obs_shocks =
                                                 cond_deviation_obs_shocks)
    end

    # clean uncond_forecast_output
    if !(:forecastobs in output_vars)
        delete!(uncond_forecast_output, :forecastobs)
    end


    return uncond_forecast_output, cond_forecast_output
end
