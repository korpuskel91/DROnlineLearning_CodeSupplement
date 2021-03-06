# Copyright (c) 2018 Robert Mieth
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
# The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
# +++++
# test_power_flow.jl
#
# Provides function to check dispatch for feasbility after observing the true load, 
# calculate balance and resulting cost
#


function run_power_flow_dr(feeder, result_df, x_observed)
    buses = feeder.buses
    lines = feeder.lines
    generators = feeder.generators

    n_buses = feeder.n_buses
    gen_bus = feeder.gen_buses
    lines_to = feeder.line_to

    A = feeder.A
    R = feeder.R
    X = feeder.X

    x_observed = max.(x_observed, 0)

    loads = [buses[b].d_P for b in 1:n_buses]
    pfs = [buses[b].tanphi for b in 1:n_buses]
    gP_opt = result_df[:gP]
    gQ_opt = result_df[:gQ]
    α_opt = result_df[:alpha]
    λ_opt = result_df[:lambda]

    load_after_dr = loads - x_observed
    error_sum = sum(load_after_dr) - sum(gP_opt)
    error_sum_Q = sum(load_after_dr.*pfs) - sum(gQ_opt)
    
    gP_balanced = gP_opt .+ (α_opt .* error_sum)
    gQ_balanced = gQ_opt .+ (α_opt .* error_sum_Q)

    gen_cost_outcome = sum(gP_balanced[b] * buses[b].generator.cost for b in gen_bus)
    dr_cost_outcome = sum(λ_opt .* x_observed)
    revenue_outcome = tariff * sum(load_after_dr)
    total_revenue = revenue_outcome - gen_cost_outcome - dr_cost_outcome

    # Calculate flows and voltages
    net_load = load_after_dr - gP_balanced
    net_load_Q = (load_after_dr.*pfs) - gQ_balanced

    if abs(sum(net_load)) > 1e-7
        warn("High active power imbalance ($(abs(sum(net_load)))), check if everything was solved correctly")
    end
    if abs(sum(net_load_Q)) > 1e-7
        warn("High reactive power imbalance ($(abs(sum(net_load_Q)))), check if everything was solved correctly")
    end

    fP_outcome = zeros(n_buses)
    fP_outcome[2:end] = A*net_load
    fQ_outcome = zeros(n_buses)
    fQ_outcome[2:end] = A*net_load_Q
    v_outcome = v_root*ones(n_buses) - 2.* A'*(R*fP_outcome[2:end] + X*fQ_outcome[2:end])

    # Test for violations
    v_violation = fill("ok", n_buses)
    for (b,v) in enumerate(v_outcome)
        v > buses[b].v_max ? v_violation[b] = "high" : nothing
        v < buses[b].v_min ? v_violation[b] = "low" : nothing
    end
    f_violation = fill("ok", n_buses)
    for l in 2:n_buses
        s = sqrt(fP_outcome[l]^2 + fQ_outcome[l]^2)
        s > lines_to[l].s_max ? f_violation[l] = "high" : nothing
    end

    outcome_df = DataFrame(
                bus=collect(1:n_buses),
                loads=loads,
                x_obs=x_observed,
                alpha=α_opt,
                v_real=sqrt.(v_outcome),
                v_violation=v_violation,
                fP=fP_outcome,
                fQ=fQ_outcome,
                f_violation=f_violation,
                revenue=fill(total_revenue, n_buses))

    return outcome_df
end