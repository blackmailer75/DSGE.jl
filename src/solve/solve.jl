"""
```
solve(m::AbstractModel; apply_altpolicy = false)
```

Driver to compute the model solution and augment transition matrices.

### Inputs

- `m`: the model object

## Keyword Arguments

- `apply_altpolicy::Bool`: whether or not to solve the model under the
  alternative policy. This should be `true` when we solve the model to
  forecast, but `false` when computing smoothed historical states (since
  the past was estimated under the baseline rule).

### Outputs
 - TTT, RRR, and CCC matrices of the state transition equation:
    ```
    S_t = TTT*S_{t-1} + RRR*ϵ_t + CCC
    ```
"""
function solve(m::AbstractModel; apply_altpolicy = false, verbose::Symbol = :high)

    altpolicy_solve = alternative_policy(m).solve


    if get_setting(m, :solution_method) == :gensys
        if altpolicy_solve == solve || !apply_altpolicy

            # Get equilibrium condition matrices
            Γ0, Γ1, C, Ψ, Π  = eqcond(m)

            # Solve model
            TTT_gensys, CCC_gensys, RRR_gensys, fmat, fwt, ywt, gev, eu, loose =
                gensys(Γ0, Γ1, C, Ψ, Π, 1+1e-6, verbose = verbose)

            # Check for LAPACK exception, existence and uniqueness
            if eu[1] != 1 || eu[2] != 1
                throw(GensysError())
            end

            TTT_gensys = real(TTT_gensys)
            RRR_gensys = real(RRR_gensys)
            CCC_gensys = real(CCC_gensys)

            # Augment states
            TTT, RRR, CCC = augment_states(m, TTT_gensys, RRR_gensys, CCC_gensys)

        else
            # Change the policy rule
            TTT, RRR, CCC = altpolicy_solve(m)
        end
    elseif get_setting(m, :solution_method) == :klein
        steadystate!(m)
        TTT_jump, TTT_state = klein(m)

        # Transition
        TTT, RRR = klein_transition_matrices(m, TTT_state, TTT_jump)
        CCC = zeros(n_model_states(m))
    end

    return TTT, RRR, CCC
end

"""
```
GensysError <: Exception
```
A `GensysError` is thrown when:

1. Gensys does not give existence and uniqueness, or
2. A LAPACK error was thrown while computing the Schur decomposition of Γ0 and Γ1

If a `GensysError`is thrown during Metropolis-Hastings, it is caught by
`posterior`.  `posterior` then returns a value of `-Inf`, which
Metropolis-Hastings always rejects.

### Fields

* `msg::String`: Info message. Default = \"Error in Gensys\"
"""
type GensysError <: Exception
    msg::String
end
GensysError() = GensysError("Error in Gensys")
Base.showerror(io::IO, ex::GensysError) = print(io, ex.msg)

# Need an additional transition_equation function to properly stack the
# individual state and jump transition matrices/shock mapping matrices to
# a single state space for all of the model_states
function klein_transition_matrices(m::AbstractModel,
                                   TTT_state::Matrix{Float64}, TTT_jump::Matrix{Float64})
    TTT = zeros(n_model_states(m), n_model_states(m))

    # Loading mapping time t states to time t+1 states
    TTT[1:n_states(m), 1:n_states(m)] = TTT_state

    # Loading mapping time t jumps to time t+1 states
    TTT[1:n_states(m), n_states(m)+1:end] = 0.

    # Loading mapping time t states to time t+1 jumps
    TTT[n_states(m)+1:end, 1:n_states(m)] = TTT_jump*TTT_state

    # Loading mapping time t jumps to time t+1 jumps
    TTT[n_states(m)+1:end, n_states(m)+1:end] = 0.

    RRR = shock_loading(m, TTT_jump)

    return TTT, RRR
end
