<script lang="ts">
  import { onMount } from 'svelte';
  import { fetchNui, isBrowser } from '../utils/nui';
  
  let vehicles = $state<any[]>([]);
  let isLoading = $state(true);

  onMount(async () => {
    if (isBrowser()) {
      // Mock data for preview
      setTimeout(() => {
        vehicles = [
          { model: 'ZENTORNO', plate: 'LS 9028', garage: 'Pillbox Hill Garage', status: 'Stored', fuel: 92, engine: 98, body: 95 },
          { model: 'SULTAN', plate: 'LS 3840', garage: 'Legion Impound', status: 'Impounded', fuel: 45, engine: 68, body: 75 },
          { model: 'ELEGY', plate: 'LS 7729', garage: 'Alta Street Garage', status: 'Out of Garage', fuel: 80, engine: 100, body: 92 }
        ];
        isLoading = false;
      }, 500);
      return;
    }

    try {
      const res = await fetchNui('getOwnedVehicles');
      vehicles = res || [];
    } catch (err) {
      console.error(err);
    } finally {
      isLoading = false;
    }
  });

  const getStatusColor = (status: string) => {
    if (status === 'Stored') return '#22c55e'; // Green
    if (status === 'Impounded') return '#ef4444'; // Red
    return '#f59e0b'; // Amber (Out)
  };

  const getHealthColor = (val: number) => {
    if (val > 80) return '#22c55e';
    if (val > 50) return '#f59e0b';
    return '#ef4444';
  };
</script>

<div class="garage-app app-transition">
  <!-- App Header -->
  <div class="app-header">
    <span class="app-title">🚗 Smart Garage</span>
  </div>

  <div class="app-content phone-scrollable">
    {#if isLoading}
      <div class="loading-state">
        <div class="spinner"></div>
        <span>Syncing satellite data...</span>
      </div>
    {:else if vehicles.length === 0}
      <div class="empty-state">
        <span>🚗</span>
        <span class="empty-text">No registered vehicles found under your license.</span>
      </div>
    {:else}
      <div class="vehicles-list">
        {#each vehicles as car}
          <div class="vehicle-card glass-card">
            <!-- Top Plate Header -->
            <div class="vehicle-top">
              <span class="model-name">{car.model}</span>
              <span class="plate-badge">{car.plate}</span>
            </div>

            <!-- Details list -->
            <div class="vehicle-details">
              <div class="detail-row">
                <span class="detail-lbl">Garage Location</span>
                <span class="detail-val">{car.garage}</span>
              </div>
              <div class="detail-row">
                <span class="detail-lbl">Status</span>
                <span class="detail-val" style="color: {getStatusColor(car.status)}">{car.status}</span>
              </div>
            </div>

            <!-- Health Status Bars -->
            <div class="health-meters">
              <!-- Fuel -->
              <div class="meter-group">
                <div class="lbl-row">
                  <span>⛽ Fuel Level</span>
                  <span>{car.fuel}%</span>
                </div>
                <div class="meter-bar-track">
                  <div class="meter-bar-fill" style="width: {car.fuel}%; background: #22c55e;"></div>
                </div>
              </div>

              <!-- Engine & Body -->
              <div class="meter-split">
                <div class="meter-group flex-1">
                  <div class="lbl-row">
                    <span>🔧 Engine</span>
                    <span>{car.engine}%</span>
                  </div>
                  <div class="meter-bar-track">
                    <div class="meter-bar-fill" style="width: {car.engine}%; background: {getHealthColor(car.engine)};"></div>
                  </div>
                </div>

                <div class="meter-group flex-1">
                  <div class="lbl-row">
                    <span>🛡️ Body</span>
                    <span>{car.body}%</span>
                  </div>
                  <div class="meter-bar-track">
                    <div class="meter-bar-fill" style="width: {car.body}%; background: {getHealthColor(car.body)};"></div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        {/each}
      </div>
    {/if}
  </div>
</div>

<style>
  .garage-app {
    display: flex;
    flex-direction: column;
    height: 100%;
    background: #09090b;
    color: #fff;
  }

  .app-header {
    height: 55px;
    display: flex;
    align-items: center;
    padding: 0 18px;
    border-bottom: 1px solid #1f1f23;
  }

  .app-title {
    font-size: 18px;
    font-weight: 700;
  }

  .app-content {
    flex: 1;
    overflow-y: auto;
    padding: 14px 16px;
    padding-bottom: 24px;
    display: flex;
    flex-direction: column;
  }

  .loading-state {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 12px;
    color: #71717a;
    font-size: 12px;
  }

  .spinner {
    width: 24px;
    height: 24px;
    border: 2px solid rgba(255,255,255,0.08);
    border-top-color: hsl(var(--phone-accent));
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin {
    100% { transform: rotate(360deg); }
  }

  .empty-state {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 14px;
    color: #71717a;
    padding: 30px;
    text-align: center;
  }

  .empty-state span:first-child {
    font-size: 40px;
  }

  .empty-text {
    font-size: 13px;
    font-weight: 500;
  }

  /* Vehicles Cards */
  .vehicles-list {
    display: flex;
    flex-direction: column;
    gap: 14px;
  }

  .vehicle-card {
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .vehicle-top {
    display: flex;
    justify-content: space-between;
    align-items: center;
    border-bottom: 1px solid rgba(255,255,255,0.06);
    padding-bottom: 8px;
  }

  .model-name {
    font-size: 15px;
    font-weight: 800;
    letter-spacing: -0.2px;
  }

  .plate-badge {
    background: #18181b;
    border: 1px solid rgba(255,255,255,0.08);
    padding: 3px 8px;
    border-radius: 6px;
    font-size: 10px;
    font-weight: bold;
    letter-spacing: 0.5px;
  }

  .vehicle-details {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .detail-row {
    display: flex;
    justify-content: space-between;
    font-size: 11.5px;
  }

  .detail-lbl {
    color: #71717a;
    font-weight: 500;
  }

  .detail-val {
    font-weight: bold;
  }

  /* Health Meters */
  .health-meters {
    display: flex;
    flex-direction: column;
    gap: 10px;
    margin-top: 4px;
  }

  .meter-group {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .lbl-row {
    display: flex;
    justify-content: space-between;
    font-size: 9px;
    font-weight: bold;
    color: #a1a1aa;
    text-transform: uppercase;
    letter-spacing: 0.2px;
  }

  .meter-bar-track {
    height: 5px;
    background: rgba(255, 255, 255, 0.05);
    border-radius: 4px;
    overflow: hidden;
  }

  .meter-bar-fill {
    height: 100%;
    border-radius: 4px;
  }

  .meter-split {
    display: flex;
    gap: 12px;
  }

  .flex-1 {
    flex: 1;
  }
</style>
