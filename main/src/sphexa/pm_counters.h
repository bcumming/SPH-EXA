#include <stdio.h>

// read a pm_counters energy file with name fname, typically one of:
//
// /sys/cray/pm_counters/accel0_energy
// /sys/cray/pm_counters/accel1_energy
// /sys/cray/pm_counters/accel2_energy
// /sys/cray/pm_counters/accel3_energy
// /sys/cray/pm_counters/cpu_energy
// /sys/cray/pm_counters/energy
// /sys/cray/pm_counters/memory_energy
//
// return the first value in the line (i.e. the cumulative energy in Joules)
int read_pm_counter_energy(const char *fname, unsigned long long* joules, unsigned long long* ns) {
    FILE *file;

    // Open the file
    file = fopen(fname, "r");
    if (file == NULL) { return 1; }

    // Scan integers nj and ts from the file
    if (fscanf(file, "%llu %*s %llu %*s", joules, ns) != 2) {
        fprintf(stderr, "ERROR: unable to parse file %s\n", fname);
        fclose(file);
        return 1;
    }

    // Close the file
    fclose(file);

    return 0;
}

struct energy {
    unsigned long long node;
    unsigned long long mod;
    unsigned long long other;
    unsigned long long cpu;
    unsigned long long memory;
    unsigned long long gpu0;
    unsigned long long gpu1;
    unsigned long long gpu2;
    unsigned long long gpu3;
    unsigned long long time;
};

energy read_energy () {
    energy reading;
#ifdef PMCOUNTERS
    unsigned long long tmp;
    read_pm_counter_energy("/sys/cray/pm_counters/energy",        &(reading.node),   &(reading.time));
    read_pm_counter_energy("/sys/cray/pm_counters/accel0_energy", &(reading.gpu0),   &tmp);
    read_pm_counter_energy("/sys/cray/pm_counters/accel1_energy", &(reading.gpu1),   &tmp);
    read_pm_counter_energy("/sys/cray/pm_counters/accel2_energy", &(reading.gpu2),   &tmp);
    read_pm_counter_energy("/sys/cray/pm_counters/accel3_energy", &(reading.gpu3),   &tmp);
    read_pm_counter_energy("/sys/cray/pm_counters/cpu_energy",    &(reading.cpu),    &tmp);
    read_pm_counter_energy("/sys/cray/pm_counters/memory_energy", &(reading.memory), &tmp);
    reading.mod =
        reading.gpu0 +
        reading.gpu1 +
        reading.gpu2 +
        reading.gpu3 +
        reading.cpu +
        reading.memory;
    reading.other = reading.node-reading.mod;
#endif

    return reading;
}

void power(const energy& start, const energy& end) {
#ifdef PMCOUNTERS
    double t = (end.time - start.time)*1e-6;
    double node  = (end.node - start.node)/t;
    double mod   = (end.mod - start.mod)/t;
    double other = (end.other - start.other)/t;
    double memory = (end.memory - start.memory)/t;
    double cpu   = (end.cpu - start.cpu)/t;
    double gpu0  = (end.gpu0 - start.gpu0)/t;
    double gpu1  = (end.gpu1 - start.gpu1)/t;
    double gpu2  = (end.gpu2 - start.gpu2)/t;
    double gpu3  = (end.gpu3 - start.gpu3)/t;
    printf("----------------------------------------------------------------------------------\n");
    printf("%10s%8s%8s%8s%8s%8s%8s%8s%8s%8s\n", "time", "node", "module", "other", "cpu", "memory", "gpu0", "gpu1", "gpu2", "gpu3");
    printf("----------------------------------------------------------------------------------\n");
    printf("%10.4f%8.1f%8.1f%8.1f%8.1f%8.1f%8.1f%8.1f%8.1f%8.1f\n",
            t, node, mod, other, cpu, memory, gpu0, gpu1, gpu2, gpu3);
    printf("----------------------------------------------------------------------------------\n");
#endif
}
