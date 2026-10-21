// nui.js — Vehicle Shop NUI Logic
// Vue 2 app, receives data via window.addEventListener('message')

Vue.filter('comma', function (value) {
  if (!value) return '0'
  return value.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',')
})

new Vue({
  el: '#app',
  data: {
    visible: false,
    shopLabel: '',
    shopName: '',
    vehicle: { brand: '', name: '', model: '', price: 0 },
    vehiclePrice: 0,
    specs: [],
    isTestDriving: false,
    testDriveMinutes: 1.5,
    showFinance: true,
    maxPayments: 24,
    minDownPercent: 10,
    downPayment: 0,
    paymentCount: 12,
  },
  computed: {
    formattedPrice: function () {
      return this.vehiclePrice.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',')
    },
    minDownAmount: function () {
      return Math.floor(this.vehiclePrice * this.minDownPercent / 100)
    },
    monthlyPayment: function () {
      if (this.downPayment < this.minDownAmount || this.paymentCount < 1) return 0
      var balance = this.vehiclePrice - this.downPayment
      return Math.floor(balance / this.paymentCount)
    },
    canAfford: function () {
      return true // Server checks actual balance
    }
  },
  methods: {
    close: function () {
      this.visible = false
      fetch('https://qb-vehicleshop/closeNui', { method: 'POST', body: '{}' })
    },
    buyVehicle: function () {
      fetch('https://qb-vehicleshop/buyVehicle', {
        method: 'POST',
        body: JSON.stringify({ vehicle: this.vehicle.model })
      })
      this.visible = false
    },
    testDrive: function () {
      this.isTestDriving = true
      fetch('https://qb-vehicleshop/testDrive', {
        method: 'POST',
        body: JSON.stringify({ vehicle: this.vehicle.model })
      })
    },
    financeVehicle: function () {
      fetch('https://qb-vehicleshop/financeVehicle', {
        method: 'POST',
        body: JSON.stringify({
          vehicle: this.vehicle.model,
          downPayment: this.downPayment,
          paymentCount: this.paymentCount
        })
      })
      this.visible = false
    },
    swapVehicle: function () {
      fetch('https://qb-vehicleshop/swapVehicle', {
        method: 'POST',
        body: JSON.stringify({})
      })
      this.visible = false
    }
  },
  mounted: function () {
    var self = this
    window.addEventListener('message', function (event) {
      var data = event.data
      if (!data || !data.type) return

      switch (data.type) {
        case 'open':
          self.visible = true
          self.shopLabel = data.shopLabel || 'Vehicle Shop'
          self.shopName = data.shopName || ''
          self.vehicle = data.vehicle || { brand: '', name: '', model: '', price: 0 }
          self.vehiclePrice = data.vehicle ? data.vehicle.price : 0
          self.specs = data.specs || []
          self.isTestDriving = data.isTestDriving || false
          self.testDriveMinutes = data.testDriveMinutes || 1.5
          self.showFinance = data.showFinance !== false
          self.maxPayments = data.maxPayments || 24
          self.minDownPercent = data.minDownPercent || 10
          self.downPayment = Math.floor(self.minDownAmount * 2)
          self.paymentCount = 12
          break

        case 'update':
          // 展示车切换：原地更新，不重置分期输入/不闪屏
          self.visible = true
          self.shopLabel = data.shopLabel || self.shopLabel
          self.shopName = data.shopName || self.shopName
          self.vehicle = data.vehicle || self.vehicle
          self.vehiclePrice = data.vehicle ? data.vehicle.price : self.vehiclePrice
          self.specs = data.specs || []
          self.showFinance = data.showFinance !== false
          self.maxPayments = data.maxPayments || self.maxPayments
          self.minDownPercent = data.minDownPercent || self.minDownPercent
          if (self.downPayment < self.minDownAmount) {
            self.downPayment = self.minDownAmount
          }
          break

        case 'close':
          self.visible = false
          break

        case 'testDriveEnd':
          self.isTestDriving = false
          break
      }
    })

    // ESC key to close
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && self.visible) {
        self.close()
      }
    })

    // Right-click to close (FiveM NUI standard)
    document.addEventListener('contextmenu', function (e) {
      if (self.visible) {
        e.preventDefault()
        self.close()
      }
    })
  }
})
