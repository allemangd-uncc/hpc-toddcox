#include <thrust/device_vector.h>
#include <thrust/host_vector.h>
#include <thrust/logical.h>

#include <vector>
#include <iostream>
#include <chrono>

#include "util.h"
#include "groups.h"

__constant__ Rel rels[128];

struct Row {
    int rel;

    int l, r;

    int from, to;

    __host__ __device__
    Row() : rel(0), l(0), r(0), from(0), to(0) {}

    __device__
    Row(int rel, int cos, int size) {
        l = 0;
        r = size - 1;
        
        from = to = cos;
        
        this->rel = rel;
    }
};

std::ostream &operator<<(std::ostream &o, const Row &r) {
    return o << "Row[" << r.rel << "]{" << r.l << ":" << r.from << "-" << r.to << ":" << r.r << "}";
}

// this performs a pass on one relation table row, applying learned data to the coset table.
struct Solver {
    int ngens;
    int *cosets;
    
    Solver(int ngens,
           thrust::device_vector<int> &cosets)
        : ngens(ngens),
           cosets(thrust::raw_pointer_cast(cosets.data())) {
    }
    
    __device__
    void operator()(Row &r) {
        if (r.r - r.l <= 0) {
            return;
        }
        
        while (r.r - r.l > 0) {
            int gen = rels[r.rel].gens[r.l & 1];
            int next = cosets[r.from * ngens + gen];
            if (next < 0) break;
            r.l++;
            r.from = next;
        }

        while (r.r - r.l > 0) {
            int gen = rels[r.rel].gens[r.r & 1];
            int next = cosets[r.to * ngens + gen];
            if (next < 0) break;
            r.r--;
            r.to = next;
        }
            
        if (r.r - r.l <= 0) { 
            int gen = rels[r.rel].gens[r.l & 1];
            cosets[r.from * ngens + gen] = r.to;
            cosets[r.to * ngens + gen] = r.from;
            return;
        }
    }
};

// this sets the inital row in the coset table based on the subgroup generators
struct CosetInitializer {
    int *cosets;

    CosetInitializer(thrust::device_vector<int> &cosets)
        : cosets(thrust::raw_pointer_cast(cosets.data())) {
    }

    __device__
    void operator()(int gen) {
        cosets[gen] = 0;
    }
};

// this creates rows for cosets by index of each relation table
struct RowGen {
    int coset;

    RowGen(int coset) 
        : coset(coset) {
    }

    __device__
    Row operator()(int rel) {
        return Row(rel, coset, rels[rel].mul * 2);
    }
};

// determines if rows are incomplete; used to remove completed rows
struct RowIncomplete {
    __device__
    bool operator()(Row r) {
        return r.r - r.l > 1;
    }
};

// add a row to the coset table filled with -1
void add_row(
        int ngens,
        thrust::device_vector<int> &cosets) {
    cosets.resize(cosets.size() + ngens, -1);
};

// add a new coset to the coset table, picking up where the last call left off.
// todo: this part is _real_ slow.
bool add_coset(
        int ngens,
        int *coset,
        int *hint,
        thrust::device_vector<int> &dcosets) {
    thrust::host_vector<int> cosets = dcosets;
    *coset = cosets.size() / ngens;

    // todo: this part especially.
    while (cosets[*hint] >= 0) {
        *hint = *hint + 1;
        if (*hint >= cosets.size()) 
            return true;
    }
    int from = *hint / ngens;
    int gen = *hint % ngens;
    
    add_row(ngens, dcosets);
    
    dcosets[*hint] = *coset;
    dcosets[*coset * ngens + gen] = from;

    return false;
}

// add a row for each relation table for some coset
void gen_rows(
        int coset,
        int nrels,
        thrust::device_vector<Row> &rows) {
    rows.resize(rows.size() + nrels);

    thrust::counting_iterator<int> counter(0);
    thrust::transform(
            thrust::device,
            counter, counter + nrels,
            rows.end() - nrels,
            RowGen(coset));
}

// do everything. data is implicitly passed to the device via device_vector.
thrust::device_vector<int> solve(
        int ngens,
        int nrels,
        thrust::device_vector<int> subs) {
    
    thrust::device_vector<int> cosets;
    thrust::device_vector<Row> rows;

    // create the inital row and populate it from subs
    add_row(ngens, cosets);
    thrust::for_each(
            thrust::device,
            subs.begin(), subs.end(), 
            CosetInitializer(cosets));

    // generate initial relation table rows for coset 0
    gen_rows(0, nrels, rows);

    // these keep track of what progress has been made
    int coset = 0;
    int hint = 0;

    // will break out later
    while (true) {
        // create a solver and apply it until nothing is being learned
        Solver solve(ngens, cosets);
        thrust::for_each(
                thrust::device,
                rows.begin(), rows.end(),
                solve);

        // fails if hint passes the end of the table. in that case, break.
        bool done = add_coset(
                ngens,
                &coset, &hint,
                cosets);
        if (done) break;

        // generate relation table rows for new coset
        gen_rows(coset, nrels, rows);

        // move completed rows to the end of the list and remove.
        auto cut = thrust::partition(
                thrust::device, 
                rows.begin(), rows.end(), 
                RowIncomplete());
        rows.erase(cut, rows.end());
    }

    return cosets;
}


int main(int argc, const char* argv[]) {
    Coxeter cox;
    cox = proc_args(argc, argv);
    std::vector<int> subs = {};

    cudaMemcpyToSymbol(rels, cox.rels.data(), cox.rels.size() * sizeof(Rel));

    auto s = std::chrono::system_clock::now();
    thrust::host_vector<int> cosets = solve(cox.ngens, cox.rels.size(), subs);
    auto e = std::chrono::system_clock::now();

    std::chrono::duration<float> diff = e - s;
    int order = cosets.size() / cox.ngens;

    // type, arg, ngens, time, order
    std::cout << cox.ngens << ',' << diff.count() << ',' << order << std::endl;

    return 0;
}

