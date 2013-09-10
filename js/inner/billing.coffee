CI.inner.Invoice = class Invoice extends CI.inner.Obj
  total: =>
    "$#{@amount_due / 100}"

  zeroize: (val) =>
    if val < 10
      "0" + val
    else
      val

  as_string: (timestamp) =>
    m = moment.unix(timestamp).utc()
    "#{m.year()}/#{@zeroize(m.month()+1)}/#{@zeroize(m.date())}"

  time_period: =>
    "#{@as_string(@period_start)} - #{@as_string(@period_end)}"

  invoice_date: =>
    "#{@as_string(@date)}"

# TODO: strip out most of billing and move it to Plan and Card
CI.inner.Billing = class Billing extends CI.inner.Obj
  observables: =>
    stripeToken: null
    cardInfo: null
    invoices: []

    # old data
    oldPlan: null
    oldTotal: 0

    # metadata
    wizardStep: 1
    planFeatures: []
    loadingOrganizations: false

    # new data
    organizations: []
    chosenPlan: null
    plans: []
    containers: 1
    payor: null
    special_price_p: null

    # org-plan data
    organization: null # org that is paying for the plan
    extra_organizations: []
    trial_end: null
    billing_name: null
    billing_email: null
    extra_data: null

    # make it work
    org_name: null # organization that instantiated the billing class

    # loaded (there has to be a better way)
    plans_loaded: false
    card_loaded: false
    invoices_loaded: false
    existing_plan_loaded: false
    orgs_loaded: false
    stripe_loaded: false

  constructor: ->
    super

    @loaded = @komp =>
      _.every ['plans', 'card', 'invoices', 'existing_plan', 'orgs', 'stripe'], (type) =>
        @["#{type}_loaded"].call()

    @savedCardNumber = @komp =>
      return "" unless @cardInfo()
      "************" + @cardInfo().last4

    @wizardCompleted = @komp =>
      @wizardStep() > 3

    @total = @komp =>
      @calculateCost(@chosenPlan(), parseInt(@containers()))

    @extra_containers = @komp =>
      if @chosenPlan()
        Math.max(0, @containers() - @chosenPlan().free_containers())

    @paid = @komp =>
      @chosenPlan() and @chosenPlan().type isnt 'trial'

    @all_orgs = @komp =>
      _.chain(@extra_organizations().concat(@organizations()))
        .sort()
        .uniq()
        .without(@organization())
        .value()

    @covered_under_other_plan = @komp =>
      @org_name() && @organization() && @org_name() isnt @organization()

  containers_option_text: (c) =>
    container_price = @chosenPlan().container_cost
    cost = @containerCost(@chosenPlan(), c)
    "#{c} containers ($#{cost})"

  containerCost: (plan, containers) ->
    c = Math.min(containers or 0, plan.max_containers())
    free_c = plan.free_containers()

    Math.max(0, (c - free_c) * plan.container_cost)

  calculateCost: (plan, containers) =>
    if plan
      plan.price + @containerCost(plan, containers)
    else
      0

  selectPlan: (plan, event) =>
    if plan.price?
      if @paid() # TODO: better way to get this info
        @oldPlan(@chosenPlan())
        @chosenPlan(plan)
        $("#confirmForm").modal({keyboard: false}) # TODO: eww
      else
        #@createCard(plan, event)
        @newPlan(plan, event)
    else
      VM.raiseIntercomDialog("I'd like ask about enterprise pricing...\n\n")

  cancelUpdate: (data, event) =>
    $('#confirmForm').modal('hide') # TODO: eww
    @chosenPlan(@oldPlan())

  ajaxSetCard: (event, token, type) =>
    $.ajax
      type: type
      url: @apiURL("card")
      event: event
      data: JSON.stringify
        token: token
      success: (data) =>
        @cardInfo(data)

  stripeDefaults: () =>
    key: @stripeKey()
    name: "CircleCI"
    address: false
    email: VM.current_user().selected_email()

  createCard: (plan, event) =>
    vals =
      panelLabel: 'Add card',
      price: 100 * plan.price
      description: "#{plan.name} plan"
      token: (token) =>
        @chosenPlan(plan)
        @recordStripeTransaction event, token

    StripeCheckout.open($.extend @stripeDefaults(), vals)


  updateCard: (data, event) =>
    vals =
      panelLabel: 'Update card',
      token: (token) =>
        @ajaxSetCard(event, token.id, "PUT")

    StripeCheckout.open($.extend @stripeDefaults(), vals)

  ajaxNewPlan: (plan_id, token, event) =>
    $.ajax
      url: @apiURL('plan')
      event: event
      type: 'POST'
      data: JSON.stringify
        token: token
        plan: plan_id
      success: (data) =>
        mixpanel.track('Paid')
        VM.org().subpage('add-containers')
        @loadPlanData(data)

  ajaxUpdatePlan: (changed_attributes, event) =>
    $.ajax
      url: @apiURL('plan')
      event: event
      type: 'PUT'
      data: JSON.stringify(changed_attributes)
      success: (data) =>
        @loadPlanData(data)

  newPlan: (plan, event) =>
    vals =
      panelLabel: 'Pay' # TODO: better label (?)
      price: 100 * plan.price
      description: "#{plan.name} plan"
      token: (token) =>
        @ajaxNewPlan(plan.id, token, event)

    StripeCheckout.open(_.extend @stripeDefaults(), vals)

  updatePlan: (data, event) =>
    @ajaxUpdatePlan {"base-template-id": @chosenPlan().id}, event
    $('#confirmForm').modal('hide') # TODO: eww
    if @wizardCompleted() # go to the speed nav
      # fight jQuery plugins with more jQuery
      $("#speed > a").click() # TODO: eww

  # TODO: make the API call return existing plan
  saveContainers: (data, event) =>
    mixpanel.track("Save Containers")
    @ajaxUpdatePlan {containers: @containers()}, event

  load: (hash="small") =>
    # TODO: Make loaded meaningful, right now it just means that
    # we triggered all the API calls
    unless @loaded()
      @loadPlans()
      @loadPlanFeatures()
      @loadExistingCard()
      @loadInvoices()
      @loadExistingPlans()
      @loadOrganizations()#
      @loadStripe()

  stripeKey: () =>
    switch renderContext.env
      when "production" then "pk_ZPBtv9wYtkUh6YwhwKRqL0ygAb0Q9"
      else 'pk_Np1Nz5bG0uEp7iYeiDIElOXBBTmtD'

  apiURL: (suffix) =>
    "/api/v1/organization/#{@org_name()}/#{suffix}"

  advanceWizard: =>
    @wizardStep(@wizardStep() + 1)

  closeWizard: =>
    @wizardStep(4)

  loadStripe: () =>
    $.getScript "https://js.stripe.com/v1/"
    # Stripe has a bug in v3 that makes ajax sends use url/form-encoded
    # instead of application/json, this breaks our ajax calls, so users
    # can't change their containers. If we want a true result, we'll
    # have to restart the test with a different name.
    if false #VM.ab().stripe_v3()
      $.getScript("https://checkout.stripe.com/v3/checkout.js")
        .success(() => @stripe_loaded(true))
    else
      $.getScript("https://checkout.stripe.com/v2/checkout.js")
        .success(() => @stripe_loaded(true))

  loadPlanData: (data) =>
    # update containers, extra_orgs, and extra invoice info
    @updateObservables(data)

    @oldTotal(data.amount / 100)
    @chosenPlan(new CI.inner.Plan(data.template_properties, @)) if data.template_properties
    @special_price_p(@oldTotal() <  @total())

  loadExistingPlans: () =>
    $.getJSON @apiURL('plan'), (data) =>
      @loadPlanData data if data
      @existing_plan_loaded(true)
      # TODO: figure out how I want to do this
      # if @chosenPlan()
      #   @closeWizard()

  loadOrganizations: () =>
    @loadingOrganizations(true)
    $.getJSON '/api/v1/user/organizations', (data) =>
      @loadingOrganizations(false)
      @organizations(org.login for org in data)
      @orgs_loaded(true)

  saveOrganizations: (data, event) =>
    mixpanel.track("Save Organizations")
    @ajaxUpdatePlan {'extra-organizations': @extra_organizations()}, event

  loadExistingCard: () =>
    $.getJSON @apiURL('card'), (card) =>
      @cardInfo card
      @card_loaded(true)

  loadInvoices: () =>
    $.getJSON @apiURL('invoices'), (invoices) =>
      if invoices
        @invoices(new Invoice(i) for i in invoices)
      @invoices_loaded(true)


  loadPlans: () =>
    $.getJSON '/api/v1/plans', (data) =>
      @plans((new CI.inner.Plan(d, @) for d in data))
      @plans_loaded(true)

  loadPlanFeatures: () =>
    @planFeatures(CI.content.pricing_features)

  popover_options: (extra) =>
    options =
      html: true
      trigger: 'hover'
      delay: 0
      animation: false
      placement: 'bottom'
     # this will break when we change bootstraps! take the new template from bootstrap.js
      template: '<div class="popover billing-popover"><div class="popover-inner"><h3 class="popover-title"></h3><div class="popover-content"></div></div></div>'

    for k, v of extra
      options[k] = v

    options
