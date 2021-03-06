# Copyright (c) 2018 Robert Mieth
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
# The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
# +++++
# model_definitions.jl
#
# Build the model using JuMP
#
# +++++
# Devnotes: ---

# Some info on settings:
# model_type = "x_opf" : run opf with the respective constraints and find optimal demand respons
# model_type = "opf" : run opf with the respective contraints and use a predefined x given by x_in
# α : if α adds up to 1 then it is used for the error control, if not alpha will be optimized#
# robust_cc : if true use robust chance constraints, if false use deterministic constraints

function run_demand_response_opf(feeder, β1, β0, μ, Σ, Ω;
     α=[], x_in=[], model_type="x_opf", robust_cc=true, enable_flow_constraints=true,
     enable_voltage_constraints=true, enable_generation_constraints=true)

    buses = feeder.buses
    lines = feeder.lines
    generators = feeder.generators
    n_buses = feeder.n_buses
    root_bus = feeder.root_bus
    gen_buses = feeder.gen_buses
    lines_to = feeder.line_to
    e = ones(n_buses)
    I = diagm(ones(n_buses))
    A = feeder.A
    R = feeder.R
    X = feeder.X
    γ = feeder.γ

    optimize_alpha = true
    if (length(α) == n_buses) && (abs(sum(α) - 1) < 1e-8)  
    # if (size(α,1) == n_buses) && (sum(α) == 1)
        optimize_alpha = false
    end

    # Prepare quadratic objective linearization
    # dr_cost: f(x) = drc_a x^2 + drc_b x + drc_c
    # NOTE: β1 can not be zero!!
    n_splits = 10
    drc_a = [1/β1[b] for b in 1:n_buses]
    drc_b = [-(β0[b] - μ[b])/β1[b] for b in 1:n_buses]
    drc_c = [-(β0[b] * μ[b])/β1[b] for b in 1:n_buses]
    dr_f(x) = drc_a .* x.^2 + drc_b .* x + drc_c
    x_max = [b.d_P for b in buses]
    split_w = x_max ./n_splits
    dr_mcs = []
    for s in 1:n_splits
        x_low = (s-1) .* split_w
        x_up = s .* split_w
        mc_vec =(dr_f(x_up) .- dr_f(x_low))./split_w
        mc_vec = map(x -> isnan(x) ? 0 : x, mc_vec)
        push!(dr_mcs, mc_vec)
    end
    nlc = dr_f(zeros(n_buses))

    # Start the Model
    model_message = ">>>>> Running"
    model_message *= robust_cc ? " robust chance constrained OPF" : " deterministic OPF"
    model_message *= model_type=="x_opf" ? " with optimal demand response" : " with predefined demand response"
    model_message *= optimize_alpha ? " and optimal participation factor" : " and predefined participation factor"
    model_message *= "."
    println(model_message)

    # Create the JuMP model and define solver
    # Change MSK_IPAR_LOG to 1 to see more solver output in the console
    m = Model(solver=MosekSolver(MSK_IPAR_LOG=0))

    # General PF Variables
    @variable(m, v[b=1:n_buses] >=0) # voltage square
    @variable(m, fp[b=1:n_buses]) # active power flow
    @variable(m, fq[b=1:n_buses]) # reactive power flow
    @variable(m, gp[b=1:n_buses]) # active power generation
    @variable(m, gq[b=1:n_buses]) # reactive power generation

    # Demand Response Variables
    if model_type == "x_opf"
        @variable(m, x_opt[b=1:n_buses] >=0) # demand reduction at bus
        @variable(m, x_opt_split[1:n_splits, 1:n_buses] >= 0) # For piecewise linear objective
    elseif model_type == "opf"
        x_opt = (length(x_in) == n_buses) ? x_in : zeros(n_buses) 
    else
        println("Unkwon Model type")
        return false
    end

    # Variables for Dist Robust Implementation
    if robust_cc
        @variable(m, s_up[b=1:n_buses]) # CVaR upper voltage constraint
        @variable(m, s_low[b=1:n_buses]) # CVaR lower voltage constraint
        @variable(m, s_gp_up[b=1:n_buses])  # CVaR upper active generation constraint
        @variable(m, s_gp_low[b=1:n_buses]) # CVaR lower active generation constraint
        @variable(m, s_gq_up[b=1:n_buses]) # CVaR upper reactive generation constraint
        @variable(m, s_gq_low[b=1:n_buses]) # CVaR lower reactive generation constraint
        @variable(m, M_up[i=1:n_buses, j=1:(n_buses+1), k=1:(n_buses+1)])
        @variable(m, M_low[i=1:n_buses, j=1:(n_buses+1), k=1:(n_buses+1)])
        @variable(m, M_gp_up[gen_buses, j=1:(n_buses+1), k=1:(n_buses+1)])
        @variable(m, M_gp_low[gen_buses, j=1:(n_buses+1), k=1:(n_buses+1)])
        @variable(m, M_gq_up[gen_buses, j=1:(n_buses+1), k=1:(n_buses+1)])
        @variable(m, M_gq_low[gen_buses, j=1:(n_buses+1), k=1:(n_buses+1)])
    end
    if (robust_cc & optimize_alpha)
        @variable(m, α[b=1:n_buses] >= 0) # Participation Factor
    end

    # +++ LinDistFlowEquations +++
    # energy balances and flows
    bus_set = collect(1:n_buses)
    @constraint(m, enerbal_P[b=bus_set], buses[b].d_P  - x_opt[b] - gp[b] + sum(fp[k] for k in buses[b].children) == fp[b])
    @constraint(m, enerbal_Q[b=bus_set], buses[b].d_Q - x_opt[b]*buses[b].tanphi - gq[b] + sum(fq[k] for k in buses[b].children) == fq[b])
    non_root_buses = setdiff(bus_set, [root_bus])
    @constraint(m, bus_voltage[b=non_root_buses], v[b] == v[buses[b].ancestor[1]] - 2*(lines_to[b].r * fp[b] + lines_to[b].x * fq[b]))
    @constraint(m, v[root_bus] == v_root)
    @constraint(m, fp[root_bus] == 0)
    @constraint(m, fq[root_bus] == 0)
    buses_without_generation = setdiff(bus_set, gen_buses)
    @constraint(m, [b=buses_without_generation], gp[b] == 0)
    @constraint(m, [b=buses_without_generation], gq[b] == 0)


    if model_type == "x_opf"
        @constraint(m, [b=bus_set], buses[b].d_P - x_opt[b] >= 0)
        @constraint(m, [b=non_dr_buses], x_opt[b] == 0)
    end

    # Force the model to do something in the initial phase
    # if current_t <= 2
    #     @constraint(m, [b=bus_set], x_opt[b] >= buses[b].d_P * 0.1)
    # end

    # constaints
    if (robust_cc & optimize_alpha)
        @constraint(m, sum(α) == 1)
        @constraint(m, [b=buses_without_generation], α[b] == 0)
    end

    # System Constraints
    C = (α*e' - I)
    T = R*A*C + X*A*C*γ
    T_i = -1.*[A[:,i]'*T for i in 1:n_buses]

    # Constraints for voltage
    if enable_voltage_constraints
        if robust_cc
            # Constraint u < u_max (upper bound)
            for b in bus_set
                # Conic constraints to enforce posiitive semiefinite matrices
                O = [zeros(n_buses, n_buses)     0.5*T_i[b]';
                       0.5*T_i[b]  v[b]-buses[b].v_max-s_up[b] ]
                @SDconstraint(m, M_up[b,:,:] >= 0)
                @SDconstraint(m, M_up[b,:,:] - O >=0)
            end
            @constraint(m, [b=bus_set], s_up[b] + 1/η_v * sum(sum(Ω[i,j]*M_up[b,j,i] for j in 1:(n_buses+1))for i in 1:(n_buses+1)) <= 0)

            #Constraint u > u_min (lower bound)
            for b in bus_set
                # Conic constraints to enforce posiitive semidefinite matrices
                O = [zeros(n_buses, n_buses)     -0.5*T_i[b]';
                       -0.5*T_i[b]  -v[b]+buses[b].v_min-s_low[b] ]
                @SDconstraint(m, M_low[b,:,:] >= 0)
                @SDconstraint(m, M_low[b,:,:] - O >=0)
            end
            @constraint(m, [b=bus_set], s_low[b] + 1/η_v * sum(sum(Ω[i,j]*M_low[b,j,i] for j in 1:(n_buses+1))for i in 1:(n_buses+1)) <= 0)
        else
            @constraint(m, [b=bus_set], v[b] <= buses[b].v_max)
            @constraint(m, [b=bus_set], v[b] >= buses[b].v_min)
        end
    end

    # Constraints for generation
    if (enable_generation_constraints & robust_cc)
        # gp < gp_max
        for b in gen_buses
            O = [zeros(n_buses, n_buses)   -0.5*α[b]*e;
                    -0.5*α[b]*e'      gp[b]-buses[b].generator.g_P_max - s_gp_up[b]]
            @SDconstraint(m, M_gp_up[b,:,:] >= 0)
            @SDconstraint(m, M_gp_up[b,:,:] - O >= 0)
        end
        @constraint(m, [b=gen_buses], s_gp_up[b] + 1/η_g * sum(sum(Ω[i,j]*M_gp_up[b,j,i] for j in 1:(n_buses+1))for i in 1:(n_buses+1)) <= 0)

        # gp > gp_min
        for b in gen_buses
            O = [zeros(n_buses, n_buses)   0.5*α[b]*e;
                    0.5*α[b]*e'      -gp[b]-s_gp_low[b]]  # min generation is zero
            @SDconstraint(m, M_gp_low[b,:,:] >= 0)
            @SDconstraint(m, M_gp_low[b,:,:] - O >= 0)
        end
        @constraint(m, [b=gen_buses], s_gp_low[b] + 1/η_g * sum(sum(Ω[i,j]*M_gp_low[b,j,i] for j in 1:(n_buses+1))for i in 1:(n_buses+1)) <= 0)

        # gq < gq_max
        for b in gen_buses
            O = [zeros(n_buses, n_buses)   -0.5*α[b]*γ*e;
                    -0.5*α[b]*(γ*e)'      gq[b]-buses[b].generator.g_Q_max - s_gq_up[b]]
            @SDconstraint(m, M_gq_up[b,:,:] >= 0)
            @SDconstraint(m, M_gq_up[b,:,:] - O >= 0)
        end
        @constraint(m, [b=gen_buses], s_gq_up[b] + 1/η_g * sum(sum(Ω[i,j]*M_gq_up[b,j,i] for j in 1:(n_buses+1))for i in 1:(n_buses+1)) <= 0)

        # gq > gq_min (-gq_max)
        for b in gen_buses
            O = [zeros(n_buses, n_buses)   0.5*α[b]*γ*e;
                    0.5*α[b]*(γ*e)'      -gq[b]-buses[b].generator.g_Q_max - s_gq_up[b]]  # min generation is -gq_max
            @SDconstraint(m, M_gq_low[b,:,:] >= 0)
            @SDconstraint(m, M_gq_low[b,:,:] - O >= 0)
        end
        @constraint(m, [b=gen_buses], s_gq_low[b] + 1/η_g * sum(sum(Ω[i,j]*M_gq_low[b,j,i] for j in 1:(n_buses+1))for i in 1:(n_buses+1)) <= 0)
    else
        # Basic Constraints on generation have alway to maintained, otherwise the problem is unbounded
        @constraint(m, [b=gen_buses], gp[b] <= buses[b].generator.g_P_max)
        @constraint(m, [b=gen_buses], gp[b] >= 0)
        @constraint(m, [b=gen_buses], gq[b] <= buses[b].generator.g_Q_max)
        @constraint(m, [b=gen_buses], gq[b] >= -buses[b].generator.g_Q_max)
    end

    # Constraints for flows
    if enable_flow_constraints
        # So far only detmerinistic constraints for flows
        @constraint(m, flow_limit[b=setdiff(bus_set, [root_bus])], lines_to[b].s_max >= norm([fp[b], fq[b]]))
    end

    # Define Objective
    # Linearization of quadratic demand response equation
    if model_type == "x_opf"
        @constraint(m, [s=1:n_splits, b=1:n_buses], x_opt_split[s,b] <= split_w[b])
        @constraint(m, [b=1:n_buses], x_opt[b] == sum(x_opt_split[s,b] for s in 1:n_splits))
        @expression(m, drCost_split, sum(nlc[b] + sum(dr_mcs[s][b]*x_opt_split[s,b] for s in 1:n_splits) for b in 1:n_buses))
    end

    mu_sum = sum(μ)
    @expression(m, genCost_lin, sum(buses[b].generator.cost * gp[b] for b in gen_buses))
    @expression(m, drCost, sum((x_opt[b] + μ[b]) * (x_opt[b] - β0[b])/β1[b] for b in bus_set))
    @expression(m, revenue, tariff * sum(buses[b].d_P - x_opt[b] - μ[b] for b in bus_set))

    if model_type == "x_opf"
        @objective(m, Min, genCost_lin + drCost_split - revenue)
    else
        @objective(m, Min, genCost_lin)
    end

    # Solve
    tic()
    status = solve(m)
    solvetime = toq()

    # Prepare Results
    objective = getobjectivevalue(m)
    result_df = DataFrame(bus=Any[], dP=Any[], gP=[], gQ=[], alpha=[], x_opt=Any[], mp=Any[], lambda=Any[], v_real=[], objective=Any[])
    for b in 1:n_buses
        xb = model_type == "x_opf" ? getvalue(x_opt[b]) : x_opt[b]
        # λb = abs(xb)>1e-10 ? ((xb - β0[b]) - μ[b])/β1[b] : 0
        λb = (xb - β0[b] - μ[b])/β1[b]
        v_squared = getvalue(v[b])
	v_real = (v_squared >= 0) ? sqrt(v_squared) : 0
        alpha = (robust_cc & optimize_alpha) ?  getvalue(α[b]) : α[b]
        res = [b, buses[b].d_P, getvalue(gp[b]), getvalue(gq[b]), alpha, xb, getdual(enerbal_P[b]), λb, v_real, getobjectivevalue(m)]
        res = map(x -> abs(x)>1e-10 ? x : 0., res) # get rid of numerical noise
        push!(result_df, res)
    end

    fP_results = zeros(n_buses)
    fP_results[2:n_buses] = [getvalue(fp[lines_to[b].index]) for b in 2:n_buses]
    fQ_results = zeros(n_buses)
    fQ_results[2:n_buses] = [getvalue(fq[lines_to[b].index]) for b in 2:n_buses]

    result_df[:fP] = fP_results
    result_df[:fQ] = fQ_results

    sort!(result_df, :bus) 

    return result_df, status, solvetime

end
