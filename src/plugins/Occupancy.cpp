#include "Occupancy.h"

void Occupancy::set(const QString& id, const QString& occupant) {
    if (!catalog_.contains(id)) return;
    if (occupant.isEmpty()) { occupant_.remove(id); return; }
    occupant_.insert(id, occupant);
}
